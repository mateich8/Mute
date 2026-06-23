import AVFoundation
import Foundation

/// The 4 Hz progress tick lives in its own object so only the scrub bar and
/// time labels re-render on it. Publishing it from Player re-rendered every
/// observing view (whole window) 4×/second, which cancelled in-flight button
/// clicks and glitched scroll positions.
@MainActor
final class PlaybackClock: ObservableObject {
    static let shared = PlaybackClock()
    @Published var elapsed: TimeInterval = 0
}

enum RepeatMode {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Playback graph: two AVAudioPlayerNodes (active + standby) → submixer →
/// 10-band EQ → main mixer. Two nodes enable gapless handoff and crossfade:
/// the upcoming track is pre-loaded on the standby node and started at a
/// host-time computed from the current track's end, so the transition is
/// sample-accurate. The submixer also sample-rate-converts per input, so
/// consecutive tracks with different formats hand off cleanly.
@MainActor
final class Player: NSObject, ObservableObject {
    static let shared = Player()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var currentIndex: Int? {
        didSet { if autoplayRadio { Task { await extendRadio() } } }
    }
    /// When on, related tracks are appended endlessly so playback never ends.
    @Published private(set) var autoplayRadio = false
    private var radioFetching = false
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffling = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published var volume: Double {
        didSet {
            engine.mainMixerNode.outputVolume = Float(volume)
            streamPlayer?.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    /// Format/bit-depth/sample-rate of the current local track (nil for streams).
    @Published private(set) var currentTechnical: TechnicalInfo?

    static let eqFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let engine = AVAudioEngine()
    private let nodeA = AVAudioPlayerNode()
    private let nodeB = AVAudioPlayerNode()
    private let submix = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private var active = 0
    private var activeNode: AVAudioPlayerNode { active == 0 ? nodeA : nodeB }
    private var standbyNode: AVAudioPlayerNode { active == 0 ? nodeB : nodeA }

    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    /// Track position where the current schedule started (changes on seek).
    private var offsetTime: TimeInterval = 0
    /// Bumped on every stop/reschedule so stale segment completions are ignored
    /// (completions also fire when a segment is interrupted by stop()).
    private var generation = 0
    /// Queue in original order, for restoring when shuffle turns off.
    private var baseQueue: [Track] = []
    private var ticker: Timer?

    // Gapless / crossfade state
    private var standbyArmed = false
    private var standbyIndex: Int?
    private var standbyFile: AVAudioFile?
    private var fadeTimer: Timer?

    // Remote addon streams play through AVPlayer: the engine path reads
    // AVAudioFile, which cannot stream over HTTP. (EQ is engine-only.)
    private var streamPlayer: AVPlayer?
    private var streamEndObserver: NSObjectProtocol?
    private(set) var playingRemote = false
    private var remoteURL: URL?

    var elapsed: TimeInterval {
        get { PlaybackClock.shared.elapsed }
        set { PlaybackClock.shared.elapsed = newValue }
    }

    override init() {
        volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 1.0
        super.init()
        engine.attach(nodeA)
        engine.attach(nodeB)
        engine.attach(submix)
        engine.attach(eq)
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let graphFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate > 0 ? hw.sampleRate : 44100,
                                        channels: 2)
        engine.connect(submix, to: eq, format: graphFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: graphFormat)
        for (i, frequency) in Self.eqFrequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        eq.globalGain = 0
        engine.mainMixerNode.outputVolume = Float(volume)
        applyEQ()
        // Keep the engine running for the app's lifetime (idle = silence). Local
        // playback then never has to start/re-acquire the output device right
        // after an AVPlayer stream is torn down, which used to race and leave
        // the first track silent until a pause/play.
        try? engine.start()
    }

    func applyEQ() {
        let settings = Settings.shared
        // Bit-perfect mode keeps the signal path untouched.
        eq.bypass = bitPerfectActive || !settings.eqEnabled
        for i in 0..<min(eq.bands.count, settings.eqGains.count) {
            eq.bands[i].gain = Float(settings.eqGains[i])
        }
    }

    // MARK: Loudness normalization

    private var loudnessRampTimer: Timer?

    /// Applies the R128 gain for the current track (or its album) by ramping
    /// the submixer volume — independent of the EQ so it works with EQ off.
    func refreshLoudness() {
        var targetDB = 0.0
        let mode = Settings.shared.normalizationMode
        if !bitPerfectActive, mode != .off, let track = current, !playingRemote {
            if let gain = mode == .album ? Library.shared.albumGain(for: track) : track.loudnessGain {
                targetDB = gain
            } else {
                // Not analyzed yet: compute in the background, apply when done.
                let id = track.id
                let url = track.url
                Task(priority: .userInitiated) {
                    let gain = LoudnessAnalyzer.analyze(url: url) ?? 0
                    await MainActor.run {
                        Library.shared.setLoudnessGain(gain, for: id)
                        if Player.shared.current?.id == id { Player.shared.refreshLoudness() }
                    }
                }
            }
        }
        rampSubmix(toDB: targetDB)
    }

    private func rampSubmix(toDB db: Double) {
        loudnessRampTimer?.invalidate()
        let target = Float(pow(10, db / 20))
        let start = submix.outputVolume
        guard abs(target - start) > 0.001 else { return }
        let begin = Date()
        let duration = 0.35
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                let t = Float(min(1, Date().timeIntervalSince(begin) / duration))
                self.submix.outputVolume = start + (target - start) * t
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        loudnessRampTimer = timer
    }

    // MARK: Bit-perfect

    @Published private(set) var bitPerfectActive = false

    /// Re-evaluates the signal path after the bit-perfect toggle changes;
    /// restarts the current local track in place so it takes effect now.
    func refreshAudioPath() {
        guard !playingRemote, let i = currentIndex, file != nil else {
            applyEQ()
            return
        }
        let resume = elapsed
        let wasPlaying = isPlaying
        play(at: i)
        if currentDuration > 0 { seek(to: resume / currentDuration) }
        if !wasPlaying { togglePlay() }
    }

    // MARK: Convenience transport (keyboard/gestures)

    func seek(by seconds: Double) {
        let duration = currentDuration
        guard duration > 0 else { return }
        seek(to: (elapsed + seconds) / duration)
    }

    func jumpToStart() { seek(to: 0) }

    func jumpToEnd() {
        let duration = currentDuration
        guard duration > 0 else { return }
        seek(to: (duration - 0.3) / duration)
    }

    private var preMuteVolume: Double?

    func toggleMute() {
        if let stored = preMuteVolume {
            volume = stored
            preMuteVolume = nil
        } else {
            preMuteVolume = volume
            volume = 0
        }
    }

    var current: Track? {
        guard let i = currentIndex, tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    /// Remote streams may differ in length from the library track's tag.
    var currentDuration: TimeInterval {
        if playingRemote {
            // Prefer a known length: YouTube reports a bogus container duration
            // to AVPlayer (the scrubber would show minutes of phantom tail).
            if let known = current?.duration, known > 0 { return known }
            if let d = streamPlayer?.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
            return 0
        }
        if let file { return Double(file.length) / file.processingFormat.sampleRate }
        return current?.duration ?? 0
    }

    var fraction: Double {
        let duration = currentDuration
        guard duration > 0 else { return 0 }
        return min(1, elapsed / duration)
    }

    // MARK: Queue control

    func play(queue: [Track], at index: Int) {
        baseQueue = queue
        if shuffling, queue.indices.contains(index) {
            let chosen = queue[index]
            tracks = [chosen] + queue.filter { $0.id != chosen.id }.shuffled()
            play(at: 0)
        } else {
            tracks = queue
            play(at: index)
        }
    }

    func play(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        // A track whose file moved or can't decode is skipped; give up after one full lap.
        var i = index
        for _ in 0..<tracks.count {
            let track = tracks[i]
            // YouTube queue entries store "ytmusic://<videoId>"; the direct
            // stream URL is resolved lazily (and re-resolved on replay, so it
            // never goes stale) right before playback.
            if track.path.hasPrefix("ytmusic://") {
                currentIndex = i
                Library.shared.registerPlay(track.id)
                NowPlayingBridge.shared.update()
                resolveAndStream(videoID: String(track.path.dropFirst(10)), forIndex: i)
                return
            }
            // Transient addon search hits store their stream URL as the path.
            if track.path.hasPrefix("http"), let url = URL(string: track.path) {
                currentIndex = i
                startRemoteStream(url)
                Library.shared.registerPlay(track.id)
                NowPlayingBridge.shared.update()
                return
            }
            if startPlayback(track.url) {
                currentIndex = i
                Library.shared.registerPlay(track.id)
                refreshTechnical()
                NowPlayingBridge.shared.update()
                return
            }
            i = (i + 1) % tracks.count
            if i == index { break }
        }
        stop()
    }

    // MARK: Autoplay radio (endless related tracks)

    func setAutoplayRadio(_ on: Bool) {
        autoplayRadio = on
        if on { Task { await extendRadio(force: true) } }
    }

    /// Keeps ~20 related tracks queued ahead, topping up (and regenerating) as
    /// they're consumed so playback never ends. Seeds from the current track,
    /// and de-dups only against tracks still AHEAD — so the pool never dries up
    /// (already-played songs may resurface later).
    private static let radioWindow = 20

    @discardableResult
    private func extendRadio(force: Bool = false) async -> Bool {
        guard autoplayRadio, !radioFetching, let ci = currentIndex, let cur = current else { return false }
        let upcoming = tracks.count - 1 - ci
        guard force || upcoming <= 5 else { return false }
        let need = Self.radioWindow - upcoming
        guard need > 0 else { return false }
        radioFetching = true
        defer { radioFetching = false }

        var seed = cur.youtubeVideoID
        if seed == nil {
            seed = await YouTubeService.shared.seedVideoID(artist: cur.artist, title: cur.title)
        }
        guard let seed else { return false }
        let results = await YouTubeService.shared.radioTracks(seed: seed)
        guard autoplayRadio, let ci2 = currentIndex else { return false }
        let ahead = Set(tracks[(ci2 + 1)...].compactMap { $0.youtubeVideoID })
        let additions = results
            .filter { $0.id != seed && !ahead.contains($0.id) }
            .prefix(need)
            .map { YouTubeService.shared.ytTrack($0, album: "", albumArtist: "", cover: $0.cover) }
        guard !additions.isEmpty else { return false }
        tracks.append(contentsOf: additions)
        return true
    }

    func playNext(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        guard let i = currentIndex else {
            play(queue: newTracks, at: 0)
            return
        }
        disarmStandby()
        tracks.insert(contentsOf: newTracks, at: i + 1)
        baseQueue.append(contentsOf: newTracks)
    }

    func addToQueue(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        guard currentIndex != nil else {
            play(queue: newTracks, at: 0)
            return
        }
        disarmStandby()
        tracks.append(contentsOf: newTracks)
        baseQueue.append(contentsOf: newTracks)
    }

    func toggleShuffle() {
        shuffling.toggle()
        guard !tracks.isEmpty else { return }
        disarmStandby()
        if baseQueue.isEmpty { baseQueue = tracks }
        if let cur = current {
            if shuffling {
                tracks = [cur] + tracks.filter { $0.id != cur.id }.shuffled()
                currentIndex = 0
            } else {
                tracks = baseQueue
                currentIndex = tracks.firstIndex { $0.id == cur.id }
            }
        } else {
            tracks = shuffling ? baseQueue.shuffled() : baseQueue
        }
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        disarmStandby()
    }

    func removeFromQueue(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        disarmStandby()
        let playing = current
        let wasPlaying = isPlaying
        let oldIndex = currentIndex ?? 0
        tracks.removeAll { ids.contains($0.id) }
        baseQueue.removeAll { ids.contains($0.id) }

        if tracks.isEmpty {
            stop()
        } else if let playing, let i = tracks.firstIndex(where: { $0.id == playing.id }) {
            currentIndex = i
        } else if wasPlaying {
            play(at: min(oldIndex, tracks.count - 1))
        } else {
            stop()
        }
    }

    // MARK: Remote streams

    /// Resolves a YouTube videoId to a playable URL off the main thread, then
    /// starts streaming it — provided the user hasn't moved on in the meantime.
    private func resolveAndStream(videoID: String, forIndex i: Int) {
        generation += 1
        let gen = generation
        nodeA.stop()
        nodeB.stop()
        file = nil
        teardownRemote()
        playingRemote = true          // treat as remote (loading) for the UI
        currentTechnical = nil
        isPlaying = true
        elapsed = 0
        stopTicker()
        Task {
            let url = await YouTubeService.shared.resolveStreamURL(videoId: videoID)
            guard gen == generation, currentIndex == i else { return }  // superseded
            if let url {
                startRemoteStream(url)
            } else if i + 1 < tracks.count {
                play(at: i + 1)           // skip a track that wouldn't resolve
            } else {
                // Couldn't resolve the only/last track. Keep it shown in the mini
                // player (paused) instead of tearing the player down — calling
                // stop() here cleared currentIndex and made the play bar vanish.
                playingRemote = false
                isPlaying = false
                stopTicker()
            }
        }
    }

    private func startRemoteStream(_ url: URL) {
        generation += 1
        disarmStandby()
        nodeA.stop()
        nodeB.stop()
        // Leave the engine running (idle, rendering silence) rather than
        // stopping it: AVPlayer and the engine are separate clients of the
        // output device, and stopping the engine here meant the next local
        // track had to re-acquire the device — the first play() raced that and
        // produced no sound until a pause/play kicked it.
        file = nil
        teardownRemote()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.trackFinished() }
        }
        streamPlayer = player
        remoteURL = url
        playingRemote = true
        currentTechnical = nil   // no local file to inspect for a stream
        player.play()
        elapsed = 0
        isPlaying = true
        startTicker()
    }

    /// Loads the current local track's format details off the main thread.
    private func refreshTechnical() {
        guard !playingRemote, let track = current else {
            currentTechnical = nil
            return
        }
        currentTechnical = nil
        Task {
            let info = await MetadataService.technicalInfo(for: track)
            await MainActor.run {
                if self.current?.id == track.id, !self.playingRemote {
                    self.currentTechnical = info
                }
            }
        }
    }

    private func teardownRemote() {
        if let observer = streamEndObserver {
            NotificationCenter.default.removeObserver(observer)
            streamEndObserver = nil
        }
        streamPlayer?.pause()
        streamPlayer = nil
        remoteURL = nil
        playingRemote = false
    }

    // MARK: Transport

    func togglePlay() {
        if playingRemote, let streamPlayer {
            if isPlaying {
                streamPlayer.pause()
                isPlaying = false
                stopTicker()
            } else {
                streamPlayer.play()
                isPlaying = true
                startTicker()
            }
            NowPlayingBridge.shared.update()
            return
        }
        guard currentIndex != nil, file != nil else {
            if !tracks.isEmpty { play(at: currentIndex ?? 0) }
            return
        }
        if isPlaying {
            disarmStandby()
            activeNode.pause()
            isPlaying = false
            stopTicker()
        } else {
            if !engine.isRunning { try? engine.start() }
            activeNode.play()
            isPlaying = true
            startTicker()
        }
        NowPlayingBridge.shared.update()
    }

    func next() {
        guard let i = currentIndex, !tracks.isEmpty else { return }
        play(at: (i + 1) % tracks.count)
    }

    func previous() {
        guard let i = currentIndex, !tracks.isEmpty else { return }
        if elapsed > 3 { seek(to: 0); return }
        play(at: (i - 1 + tracks.count) % tracks.count)
    }

    func seek(to fraction: Double) {
        if playingRemote, let streamPlayer {
            let duration = currentDuration
            guard duration > 0 else { return }
            let time = max(0, min(duration, fraction * duration))
            streamPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            elapsed = time
            NowPlayingBridge.shared.update()
            return
        }
        guard let file, current != nil else { return }
        let duration = Double(file.length) / sampleRate
        let time = max(0, min(duration, fraction * duration))
        let wasPlaying = isPlaying
        generation += 1
        disarmStandby()
        activeNode.stop()
        offsetTime = time
        scheduleSegment(from: AVAudioFramePosition(time * sampleRate), on: activeNode)
        if wasPlaying { activeNode.play() }
        elapsed = time
        NowPlayingBridge.shared.update()
    }

    func stop() {
        generation += 1
        disarmStandby()
        nodeA.stop()
        nodeB.stop()
        // Engine stays running (see init) so the next play doesn't race the
        // output device; just silence the player nodes.
        file = nil
        teardownRemote()
        stopTicker()
        currentIndex = nil
        isPlaying = false
        elapsed = 0
        NowPlayingBridge.shared.update()
    }

    // MARK: Engine plumbing

    private func startPlayback(_ url: URL) -> Bool {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return false }
        generation += 1
        disarmStandby()
        teardownRemote()
        nodeA.stop()
        nodeB.stop()
        file = audioFile
        sampleRate = audioFile.processingFormat.sampleRate

        // Bit-perfect: drive the DAC at the file's rate and rebuild the graph
        // rate-matched so no SRC happens anywhere; falls back silently.
        let wantBitPerfect = Settings.shared.bitPerfect
        let newBitPerfect = wantBitPerfect && BitPerfect.matchDeviceRate(to: sampleRate)
        if newBitPerfect != bitPerfectActive || newBitPerfect {
            bitPerfectActive = newBitPerfect
            engine.stop()
            let rate = newBitPerfect ? sampleRate : (engine.outputNode.outputFormat(forBus: 0).sampleRate)
            if let graphFormat = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44100, channels: 2) {
                engine.connect(submix, to: eq, format: graphFormat)
                engine.connect(eq, to: engine.mainMixerNode, format: graphFormat)
            }
        }

        // Reconnecting a stopped node while the engine runs is supported and
        // keeps the engine alive across track changes (required for gapless).
        engine.connect(activeNode, to: submix, format: audioFile.processingFormat)
        if !engine.isRunning {
            guard (try? engine.start()) != nil else { return false }
        }
        applyEQ()
        refreshLoudness()
        offsetTime = 0
        activeNode.volume = 1
        scheduleSegment(from: 0, on: activeNode)
        activeNode.play()
        elapsed = 0
        isPlaying = true
        startTicker()
        return true
    }

    private func scheduleSegment(from frame: AVAudioFramePosition, on node: AVAudioPlayerNode) {
        guard let file else { return }
        let remaining = AVAudioFrameCount(max(0, file.length - frame))
        guard remaining > 0 else { return }
        let gen = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentEnded(generation: gen) }
        }
    }

    private var position: TimeInterval {
        if playingRemote {
            let t = streamPlayer?.currentTime().seconds ?? 0
            return t.isFinite ? t : 0
        }
        guard let nodeTime = activeNode.lastRenderTime,
              let playerTime = activeNode.playerTime(forNodeTime: nodeTime) else { return offsetTime }
        return offsetTime + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func segmentEnded(generation gen: Int) {
        guard gen == generation else { return }
        if standbyArmed {
            completeHandoff()
        } else {
            trackFinished()
        }
    }

    private func trackFinished() {
        switch repeatMode {
        case .one:
            if playingRemote, let remoteURL {
                startRemoteStream(remoteURL)
            } else if let i = currentIndex {
                play(at: i)
            }
        case .all:
            next()
        case .off:
            if let i = currentIndex, i + 1 < tracks.count {
                play(at: i + 1)
            } else if autoplayRadio, let i = currentIndex {
                // Endless radio: the queue emptied before more arrived — fetch a
                // fresh batch, then keep going (never stop).
                Task {
                    let added = await extendRadio(force: true)
                    if added, i + 1 < tracks.count {
                        play(at: i + 1)
                    } else {
                        isPlaying = false; stopTicker(); seek(to: 0)
                        NowPlayingBridge.shared.update()
                    }
                }
            } else {
                isPlaying = false
                stopTicker()
                seek(to: 0)
                NowPlayingBridge.shared.update()
            }
        }
    }

    // MARK: Gapless / crossfade

    /// Called from the ticker: when the current track approaches its end,
    /// pre-load the next one on the standby node and schedule it to start at
    /// the exact host time the current one finishes (or earlier, to crossfade).
    private func maybeArmNext() {
        // Bit-perfect mode never overlaps or pre-mixes tracks.
        guard !playingRemote, !bitPerfectActive, isPlaying, !standbyArmed,
              file != nil, let i = currentIndex else { return }
        let nextIndex: Int?
        switch repeatMode {
        case .one: nextIndex = i
        case .all: nextIndex = tracks.isEmpty ? nil : (i + 1) % tracks.count
        case .off: nextIndex = i + 1 < tracks.count ? i + 1 : nil
        }
        guard let nextIndex else { return }
        let crossfade = Settings.shared.crossfade
        let remaining = currentDuration - elapsed
        guard remaining > 0.35, remaining <= crossfade + 8 else { return }
        armStandby(nextIndex: nextIndex, requestedFade: crossfade)
    }

    private func armStandby(nextIndex: Int, requestedFade: Double) {
        guard tracks.indices.contains(nextIndex),
              let file,
              let nodeTime = activeNode.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = activeNode.playerTime(forNodeTime: nodeTime),
              let nextFile = try? AVAudioFile(forReading: tracks[nextIndex].url) else { return }

        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        let total = Double(file.length) / file.processingFormat.sampleRate
        let remaining = total - offsetTime - played
        guard remaining > 0.25 else { return }

        let nextDuration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        let fade = min(requestedFade, max(0, remaining - 0.1), nextDuration * 0.5)

        let node = standbyNode
        node.stop()
        engine.connect(node, to: submix, format: nextFile.processingFormat)

        standbyArmed = true
        standbyIndex = nextIndex
        standbyFile = nextFile
        let gen = generation
        node.scheduleSegment(nextFile, startingFrame: 0, frameCount: AVAudioFrameCount(nextFile.length),
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentEnded(generation: gen) }
        }
        let endHost = nodeTime.hostTime + AVAudioTime.hostTime(forSeconds: remaining)
        if fade > 0.05 {
            node.volume = 0
            let startHost = nodeTime.hostTime + AVAudioTime.hostTime(forSeconds: max(0, remaining - fade))
            node.play(at: AVAudioTime(hostTime: startHost))
            startFade(duration: fade, beginIn: max(0, remaining - fade))
        } else {
            node.volume = 1
            node.play(at: AVAudioTime(hostTime: endHost))
        }
    }

    /// Equal-power fade between the two nodes, stepped at 30 Hz.
    private func startFade(duration: Double, beginIn delay: Double) {
        fadeTimer?.invalidate()
        let start = Date().addingTimeInterval(delay)
        let timer = Timer(fire: start, interval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.standbyArmed else { timer.invalidate(); return }
                let t = min(1, max(0, Date().timeIntervalSince(start) / duration))
                self.standbyNode.volume = Float(sin(t * .pi / 2))
                self.activeNode.volume = Float(cos(t * .pi / 2))
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    /// The old track's segment just finished while the standby node is already
    /// playing the next one — promote standby to active.
    private func completeHandoff() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        activeNode.stop()
        active = 1 - active
        activeNode.volume = 1
        standbyNode.volume = 1
        file = standbyFile
        sampleRate = file?.processingFormat.sampleRate ?? 44100
        offsetTime = 0
        currentIndex = standbyIndex
        standbyArmed = false
        standbyIndex = nil
        standbyFile = nil
        isPlaying = true
        elapsed = position
        refreshLoudness()
        Library.shared.registerPlay(current?.id)
        NowPlayingBridge.shared.update()
    }

    private func disarmStandby() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard standbyArmed else {
            nodeA.volume = 1
            nodeB.volume = 1
            return
        }
        standbyNode.stop()
        standbyArmed = false
        standbyIndex = nil
        standbyFile = nil
        nodeA.volume = 1
        nodeB.volume = 1
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.elapsed = self.position
                self.maybeArmNext()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

func timestamp(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}
