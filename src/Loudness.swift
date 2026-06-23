import AVFoundation
import Foundation

/// EBU R128 / ITU-R BS.1770 integrated loudness: K-weighting (pre-shelf +
/// RLB high-pass biquads, coefficients designed per sample rate the same way
/// libebur128 does), 400 ms blocks with 75% overlap, -70 LUFS absolute gate,
/// then a -10 LU relative gate.
enum LoudnessAnalyzer {
    static let targetLUFS = -23.0

    /// Returns the gain (dB, clamped -12…+6) to bring the file to -23 LUFS.
    nonisolated static func analyze(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        guard sr > 0, channels > 0 else { return nil }

        let pre = Biquad.kWeightPre(sampleRate: sr)
        let rlb = Biquad.kWeightRLB(sampleRate: sr)
        var filters: [[Biquad]] = (0..<channels).map { _ in [pre, rlb] }

        let blockSize = Int(sr * 0.4)
        let hopSize = blockSize / 4
        var ringEnergy = [Double](repeating: 0, count: channels)
        var window = [[Float]](repeating: [], count: channels)
        var blockPowers: [Double] = []

        let chunkFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        var pending = [[Float]](repeating: [], count: channels)
        while file.framePosition < file.length {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: chunkFrames)) != nil, buffer.frameLength > 0 else { break }
            guard let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            for c in 0..<channels {
                var samples = [Float](UnsafeBufferPointer(start: data[c], count: frames))
                filters[c][0].process(&samples)
                filters[c][1].process(&samples)
                pending[c].append(contentsOf: samples)
            }
            // Consume whole hops
            while pending[0].count >= hopSize {
                for c in 0..<channels {
                    let hop = pending[c][0..<hopSize]
                    var sum: Double = 0
                    for s in hop { sum += Double(s) * Double(s) }
                    window[c].append(contentsOf: hop)
                    if window[c].count > blockSize { window[c].removeFirst(window[c].count - blockSize) }
                    ringEnergy[c] = window[c].reduce(0) { $0 + Double($1) * Double($1) }
                    _ = sum
                    pending[c].removeFirst(hopSize)
                }
                if window[0].count >= blockSize {
                    var power: Double = 0
                    for c in 0..<channels {
                        power += ringEnergy[c] / Double(blockSize)   // channel weight 1.0 (L/R/C)
                    }
                    blockPowers.append(power)
                }
            }
        }
        _ = pre; _ = rlb
        guard !blockPowers.isEmpty else { return nil }

        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-12)) }

        // Absolute gate at -70 LUFS
        let absGated = blockPowers.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        // Relative gate at (ungated mean - 10 LU)
        let relThreshold = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let relGated = absGated.filter { lufs($0) > relThreshold }
        guard !relGated.isEmpty else { return nil }
        let integrated = lufs(relGated.reduce(0, +) / Double(relGated.count))
        guard integrated.isFinite else { return nil }
        return min(6, max(-12, targetLUFS - integrated))
    }
}

/// Direct-form-II biquad; coefficient design matches libebur128's analytic
/// re-derivation of the ITU 48 kHz prototypes for arbitrary sample rates.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            let x = Double(samples[i])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[i] = Float(y)
        }
    }

    static func kWeightPre(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0,
                      b1: 2 * (k * k - vh) / a0,
                      b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / q + k * k) / a0)
    }

    static func kWeightRLB(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / q + k * k) / a0)
    }
}

/// Background sweep that fills in missing loudness gains, one file at a time
/// at utility priority. Kicked when normalization is enabled and on import.
@MainActor
final class LoudnessScanner {
    static let shared = LoudnessScanner()
    private var running = false

    func kick() {
        guard !running, Settings.shared.normalizationMode != .off else { return }
        running = true
        Task(priority: .utility) { [weak self] in
            while true {
                let next = await MainActor.run { () -> Track? in
                    Library.shared.tracks.first { $0.loudnessGain == nil }
                }
                guard let track = next else { break }
                let gain = LoudnessAnalyzer.analyze(url: track.url) ?? 0
                await MainActor.run {
                    Library.shared.setLoudnessGain(gain, for: track.id)
                    if Player.shared.current?.id == track.id { Player.shared.refreshLoudness() }
                }
                if await MainActor.run(body: { Settings.shared.normalizationMode == .off }) { break }
            }
            await MainActor.run { self?.running = false }
        }
    }
}
