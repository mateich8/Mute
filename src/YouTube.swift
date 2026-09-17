import SwiftUI
import Foundation
import Network

// MARK: - Models

/// A song / video result. `id` is the 11-character YouTube videoId.
struct YTResult: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
    var trackNumber: Int? = nil
    /// Official album cover from YouTube Music, when known.
    var cover: URL? = nil

    /// Square thumbnail for list rows: the album cover if known, else the
    /// video thumbnail derived from the id.
    var thumbnailURL: URL { cover ?? URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
}

/// An artist profile. `id` is the YouTube Music browse/channel id.
struct YTArtist: Identifiable, Equatable {
    let id: String
    let name: String
    let thumb: URL?
}

/// An album, single or EP. `id` is the browseId used to fetch the tracklist.
struct YTAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let year: String          // "" when unknown
    let kind: String          // "Album" / "Single" / "EP"
    let thumb: URL?
}

/// An artist's catalogue, split the way a streaming app shows it.
struct YTArtistDetail: Equatable {
    let name: String
    let thumb: URL?
    let bio: String
    let subscribers: String
    let albums: [YTAlbum]
    let singles: [YTAlbum]
    let topSongs: [YTResult]
    var related: [YTArtist] = []
}

/// A single timed lyric line (time in seconds from the track start).
struct LyricLine: Equatable, Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

/// Lyrics for a track: timed `lines` when available, else `plain` text.
struct Lyrics: Equatable {
    let lines: [LyricLine]
    let plain: String
    var synced: Bool { !lines.isEmpty }
    var isEmpty: Bool { lines.isEmpty && plain.isEmpty }
}

/// Trivia for the now-playing track (per-song from Wikipedia/Genius, or the
/// artist bio as a last resort).
struct SongTrivia: Equatable {
    let text: String
    let subtitle: String   // e.g. release date or "N subscribers"
    let source: String     // "Wikipedia" / "Genius" / "" (bio)
    let url: String        // article/source link, if any
}

/// A fully-resolved album with its tracklist in play order.
struct YTAlbumDetail: Equatable {
    let id: String
    let title: String
    let artist: String
    let year: String
    let thumb: URL?
    let tracks: [YTResult]
}

/// Where the YouTube tab is currently navigated.
enum YTRoute: Equatable {
    case search
    case artist(id: String, name: String)
    case album(id: String, title: String)
}

/// A human-readable failure carried back from the background tool calls.
struct YTError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Per-result download progress, surfaced in the result row.
enum DownloadState: Equatable {
    case downloading(Double)   // 0…1, or negative for indeterminate
    case done
    case failed(String)
}

// MARK: - Service

/// The YouTube Music extension. Two external pieces do the work:
///   • `ytmusicapi` (in a private venv) is the structure/metadata layer — it
///     gives typed artists, albums and tracklists, the way a streaming app
///     needs them; flat video search can't categorise albums vs singles.
///   • `yt-dlp` (+ `ffmpeg`) is the media layer — it resolves a videoId to a
///     playable stream and downloads audio.
/// Streaming queues store "ytmusic://<videoId>" and resolve lazily through the
    /// Player; downloads land in ~/Music/Mute/YouTube and import as tracks.
@MainActor
final class YouTubeService: ObservableObject {
    static let shared = YouTubeService()

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "ytEnabled")
            if enabled { refreshTool() }
        }
    }
    @Published var query = ""

    // Structured search results
    @Published private(set) var artists: [YTArtist] = []
    @Published private(set) var albums: [YTAlbum] = []
    @Published private(set) var songs: [YTResult] = []
    @Published private(set) var searching = false
    @Published private(set) var statusMessage: String?

    // Navigation (search → artist → album)
    @Published private(set) var routeStack: [YTRoute] = [.search]
    @Published private(set) var artistDetail: YTArtistDetail?
    @Published private(set) var albumDetail: YTAlbumDetail?
    @Published private(set) var loadingDetail = false
    var route: YTRoute { routeStack.last ?? .search }
    private var artistCache: [String: YTArtistDetail] = [:]
    private var albumCache: [String: YTAlbumDetail] = [:]

    // Downloads / environment
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var online = true
    @Published private(set) var tool: ToolStatus = .checking
    @Published private(set) var installing = false
    @Published private(set) var installLog = ""

    enum ToolStatus: Equatable {
        case checking
        case ready(version: String, ffmpeg: Bool)
        case missing(detail: String)
    }

    private let defaults = UserDefaults.standard
    private let monitor = NWPathMonitor()
    private var searchTask: Task<Void, Never>?
    private var cachedPaths: [String: String] = [:]

    /// App-support root, shared with the rest of the app.
    nonisolated static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Mute")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Downloaded songs live here and import into the library.
    nonisolated static let downloadDir: URL = {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let dir = base.appendingPathComponent("Mute/YouTube")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        enabled = defaults.object(forKey: "ytEnabled") as? Bool ?? true
        Self.ensureHelper()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "mute.network.monitor"))
        if enabled { refreshTool() }
    }

    // MARK: Tool discovery

    func path(for tool: String) -> String? {
        if let cached = cachedPaths[tool] { return cached.isEmpty ? nil : cached }
        let found = Self.locate(tool)
        cachedPaths[tool] = found ?? ""
        return found
    }

    nonisolated static func locate(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/",
                    NSHomeDirectory() + "/.local/bin/"]
        for dir in dirs {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let r = runSync("/bin/zsh", ["-lc", "command -v \(name)"])
        let line = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0 && FileManager.default.isExecutableFile(atPath: line)) ? line : nil
    }

    nonisolated static func venvPython() -> String? {
        let p = appSupportDir.appendingPathComponent("pyenv/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// True when the venv exists and `ytmusicapi` imports cleanly.
    nonisolated static func ytmusicReady() -> Bool {
        guard let py = venvPython() else { return false }
        return runSync(py, ["-c", "import ytmusicapi"]).code == 0
    }

    func refreshTool() {
        tool = .checking
        cachedPaths.removeAll()
        Self.ensureHelper()
        // Low priority so the Python `import ytmusicapi` probe doesn't compete
        // with the UI coming up at launch.
        Task.detached(priority: .utility) {
            let ytdlp = Self.locate("yt-dlp")
            let music = Self.ytmusicReady()
            let status: ToolStatus
            if let ytdlp, music {
                let version = Self.runSync(ytdlp, ["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
                status = .ready(version: version.isEmpty ? "installed" : version, ffmpeg: Self.locate("ffmpeg") != nil)
            } else {
                var missing: [String] = []
                if ytdlp == nil { missing.append("yt-dlp") }
                if !music { missing.append("the music library") }
                status = .missing(detail: missing.joined(separator: " and "))
            }
            await MainActor.run { YouTubeService.shared.tool = status }
        }
    }

    var ready: Bool { if case .ready = tool { return true } else { return false } }
    var hasFFmpeg: Bool { if case .ready(_, let ff) = tool { return ff } else { return false } }
    var toolChecking: Bool { tool == .checking }
    var missingDetail: String? { if case .missing(let d) = tool { return d } else { return nil } }

    // MARK: Search (structured)

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        routeStack = [.search]
        artistDetail = nil; albumDetail = nil
        guard !q.isEmpty else { artists = []; albums = []; songs = []; statusMessage = nil; return }
        guard ready else { return }
        guard online else { statusMessage = "You’re offline — connect to search YouTube."; return }
        searching = true
        statusMessage = nil
        searchTask = Task {
            let outcome = await Task.detached { Self.fetchSearch(q) }.value
            if Task.isCancelled { return }
            searching = false
            switch outcome {
            case .success(let r):
                artists = r.artists; albums = r.albums; songs = r.songs
                statusMessage = (r.artists.isEmpty && r.albums.isEmpty && r.songs.isEmpty)
                    ? "No results for “\(q)”." : nil
            case .failure(let e):
                artists = []; albums = []; songs = []
                statusMessage = e.localizedDescription
            }
        }
    }

    // MARK: Navigation

    func openArtist(id: String, name: String) {
        routeStack.append(.artist(id: id, name: name))
        if let cached = artistCache[id] { artistDetail = cached; loadingDetail = false; return }
        artistDetail = nil; loadingDetail = true
        Task {
            let detail = await Task.detached { Self.fetchArtist(id) }.value
            if let detail { artistCache[id] = detail }
            if case .artist(let current, _) = route, current == id {
                artistDetail = detail
                loadingDetail = false
            }
        }
    }

    func openAlbum(id: String, title: String) {
        routeStack.append(.album(id: id, title: title))
        if let cached = albumCache[id] { albumDetail = cached; loadingDetail = false; return }
        albumDetail = nil; loadingDetail = true
        Task {
            let detail = await Task.detached { Self.fetchAlbum(id) }.value
            if let detail { albumCache[id] = detail }
            if case .album(let current, _) = route, current == id {
                albumDetail = detail
                loadingDetail = false
            }
        }
    }

    func back() {
        guard routeStack.count > 1 else { return }
        routeStack.removeLast()
        switch route {
        case .search:
            break
        case .artist(let id, _):
            artistDetail = artistCache[id]; loadingDetail = artistDetail == nil
        case .album(let id, _):
            albumDetail = albumCache[id]; loadingDetail = albumDetail == nil
        }
    }

    // MARK: Playback

    func ytTrack(_ r: YTResult, album: String, albumArtist: String, cover: URL?) -> Track {
        Track(path: "ytmusic://\(r.id)", title: r.title, artist: r.artist, album: album,
              albumArtist: albumArtist.isEmpty ? nil : albumArtist,
              trackNumber: r.trackNumber, duration: r.duration,
              artworkURL: (r.cover ?? cover)?.absoluteString)
    }

    /// Streams a single song (or plays the local copy if already downloaded).
    func play(_ result: YTResult) {
        if isDownloaded(result.id) { playDownloaded(result); return }
        guard online else { statusMessage = "You’re offline — connect to stream from YouTube."; return }
        Player.shared.play(queue: [ytTrack(result, album: "", albumArtist: "", cover: result.cover)], at: 0)
    }

    /// Plays an album as a queue starting at `index`, in tracklist order. The
    /// album cover is used as artwork for every track.
    func playAlbum(_ detail: YTAlbumDetail, startAt index: Int = 0) {
        guard online else { statusMessage = "You’re offline — connect to stream from YouTube."; return }
        let queue = detail.tracks.map {
            ytTrack($0, album: detail.title, albumArtist: detail.artist, cover: detail.thumb)
        }
        guard !queue.isEmpty else { return }
        Player.shared.play(queue: queue, at: min(max(0, index), queue.count - 1))
    }

    // MARK: Add to library (streaming — no download)

    /// Adds a single song to the library as a streaming entry. It appears in
    /// Songs (and as its own single in Albums) and plays by streaming.
    func addToLibrary(_ result: YTResult) {
        let track = ytTrack(result, album: result.title, albumArtist: result.artist, cover: result.cover)
        Library.shared.addStreaming([track])
    }

    /// Adds a whole album to the library as streaming entries (proper album with
    /// track numbers), without downloading any audio.
    func addAlbumToLibrary(_ detail: YTAlbumDetail) {
        let tracks = detail.tracks.enumerated().map { i, t -> Track in
            var r = t
            if r.trackNumber == nil { r.trackNumber = i + 1 }
            return ytTrack(r, album: detail.title, albumArtist: detail.artist, cover: detail.thumb)
        }
        Library.shared.addStreaming(tracks)
    }

    func isInLibrary(_ id: String) -> Bool { Library.shared.isInLibrary(youtubeID: id) }

    /// Adds a YouTube song to a playlist: imports it as a streaming library
    /// entry (if not already there), then appends it to the playlist.
    func addToPlaylist(_ result: YTResult, playlist id: UUID) {
        let track = ytTrack(result, album: result.title, albumArtist: result.artist, cover: result.cover)
        let added = Library.shared.addStreaming([track])
        let libTrack = added.first ?? Library.shared.tracks.first { $0.path == track.path }
        if let libTrack { Library.shared.add(trackIDs: [libTrack.id], to: id) }
    }

    /// Lightweight song-only search that returns results without mutating the
    /// shared search state (used by the Add-to-playlist picker).
    func searchSongs(_ query: String) async -> [YTResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, online, !q.isEmpty else { return [] }
        return await Task.detached { () -> [YTResult] in
            let (data, _) = Self.runHelper(["search", q])
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = obj["songs"] as? [[String: Any]] else { return [] }
            return songs.compactMap { s in
                guard let id = s["id"] as? String, let title = s["title"] as? String else { return nil }
                let cover = (s["thumb"] as? String).flatMap { URL(string: $0) }
                return YTResult(id: id, title: title, artist: (s["artist"] as? String) ?? "",
                                duration: (s["duration"] as? Double) ?? 0, cover: cover)
            }
        }.value
    }

    /// Fetches an artist's YouTube Music bio text (used to infer genre).
    func artistBio(name: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, online, !n.isEmpty else { return nil }
        return await Task.detached { () -> String? in
            let (data, _) = Self.runHelper(["bio", n])
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bio = obj["bio"] as? String, !bio.isEmpty else { return nil }
            return bio
        }.value
    }

    // MARK: Autoplay radio data

    func radioTracks(seed videoID: String) async -> [YTResult] {
        guard ready else { return [] }
        return await Task.detached { Self.fetchRadio(videoID) }.value
    }

    /// Finds a YouTube videoId for a (likely local) track so radio can seed from it.
    func seedVideoID(artist: String, title: String) async -> String? {
        guard ready else { return nil }
        let q = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return await Task.detached { () -> String? in
            let (data, _) = Self.runHelper(["search", q])
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = obj["songs"] as? [[String: Any]] else { return nil }
            return songs.first?["id"] as? String
        }.value
    }

    nonisolated private static func fetchRadio(_ videoID: String) -> [YTResult] {
        let (data, _) = runHelper(["radio", videoID])
        guard let data else { return [] }
        struct Raw: Decodable {
            let id: String; let title: String; let artist: String
            let duration: Double?; let type: String?; let thumb: String?
        }
        guard let arr = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        // Keep only official audio ("art tracks", ATV) — clean audio + square
        // album covers — and drop anything titled like a video/live clip.
        func isVideoTitle(_ t: String) -> Bool {
            let l = t.lowercased()
            return l.contains("official video") || l.contains("music video")
                || l.contains("lyric video") || l.contains("(live") || l.contains("visualizer")
        }
        let pool = arr.filter { $0.type == "MUSIC_VIDEO_TYPE_ATV" && !isVideoTitle($0.title) }
        return pool.map {
            YTResult(id: $0.id, title: $0.title, artist: $0.artist,
                     duration: $0.duration ?? 0, cover: url($0.thumb))
        }
    }

    // MARK: New releases (New tab)

    @Published private(set) var newReleases: [YTAlbum] = []
    @Published private(set) var newReleasesLoading = false
    @Published private(set) var artistNew: [YTAlbum] = []    // latest releases from the user's artists
    @Published private(set) var similarNew: [YTAlbum] = []   // latest releases from genre-similar artists
    @Published private(set) var artistNewLoading = false
    private var artistNewLoaded = false

    /// The New tab, built entirely from the user's taste: the latest album + single
    /// from each of their library artists, then new releases from genre-similar
    /// (YouTube "related") artists — never a generic region feed.
    func loadArtistNew(force: Bool = false) {
        guard ready, online, force || !artistNewLoaded else { return }
        // Prefer most-played artists; fill out with the rest of the library.
        var names = Library.shared.topArtists.prefix(12).map(\.name).filter { !$0.isEmpty }
        if names.count < 12 {
            let distinct = Array(Set(Library.shared.tracks.map(\.artist)
                .filter { !$0.isEmpty && $0 != "Unknown Artist" })).sorted()
            for a in distinct where !names.contains(a) {
                names.append(a); if names.count >= 12 { break }
            }
        }
        guard !names.isEmpty else { return }
        artistNewLoaded = true
        artistNewLoading = true
        let userArtists = Set(Library.shared.tracks.map { Self.norm($0.artist) })
        Task {
            var out: [YTAlbum] = []
            var seen = Set<String>()
            var relatedById: [String: YTArtist] = [:]
            for name in names {
                guard let detail = await Task.detached(operation: { Self.fetchArtistByName(name) }).value else { continue }
                for a in [detail.albums.first, detail.singles.first].compactMap({ $0 }) where !seen.contains(a.id) {
                    seen.insert(a.id); out.append(a)
                }
                for r in detail.related where !r.name.isEmpty && !userArtists.contains(Self.norm(r.name)) {
                    relatedById[r.id] = r
                }
                if !out.isEmpty { artistNew = out }     // progressive reveal
            }
            artistNewLoading = false
            loadSimilarNew(from: Array(relatedById.values), excluding: seen)
        }
    }

    /// New releases from genre-similar (related) artists — discovery that still
    /// matches the user's taste (related artists share genre/scene).
    private func loadSimilarNew(from related: [YTArtist], excluding seenAlbums: Set<String>) {
        let pick = Array(related.shuffled().prefix(12))
        guard !pick.isEmpty else { return }
        Task {
            var out: [YTAlbum] = []
            var seen = seenAlbums
            for artist in pick {
                let detail = await Task.detached(operation: { Self.fetchArtist(artist.id) }).value
                if let a = detail?.albums.first ?? detail?.singles.first, !seen.contains(a.id) {
                    seen.insert(a.id); out.append(a)
                    similarNew = out                    // progressive reveal
                }
            }
        }
    }

    /// Loads region new-release albums from the YT Music home feed (once).
    func loadNewReleases(force: Bool = false) {
        guard ready, online, !newReleasesLoading, force || newReleases.isEmpty else { return }
        newReleasesLoading = true
        Task {
            let albums = await Task.detached { () -> [YTAlbum] in
                let (data, _) = Self.runHelper(["explore"])
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let arr = obj["newAlbums"] as? [[String: Any]] else { return [] }
                return arr.compactMap { a in
                    guard let id = a["id"] as? String, let title = a["title"] as? String else { return nil }
                    return YTAlbum(id: id, title: title, artist: (a["artist"] as? String) ?? "",
                                   year: (a["year"] as? String) ?? "", kind: (a["kind"] as? String) ?? "Album",
                                   thumb: (a["thumb"] as? String).flatMap { URL(string: $0) })
                }
            }.value
            if !albums.isEmpty { newReleases = albums }
            newReleasesLoading = false
        }
    }

    // MARK: Recommendations (For You)

    @Published private(set) var recommendations: [YTResult] = []
    @Published private(set) var recommendationsLoading = false
    private var recsSeed: String?

    /// Builds "similar songs" recommendations, seeded from what's currently
    /// playing, else the most-played track, else the top artist — excluding
    /// tracks already in the library.
    func loadRecommendations(force: Bool = false) {
        guard ready, online, !recommendationsLoading else { return }
        let cur = Player.shared.current
        let seedTrack = (cur?.youtubeVideoID != nil)
            ? cur : Library.shared.mostPlayed.first(where: { $0.youtubeVideoID != nil })
        let topArtist = Library.shared.topArtists.first?.name
        Task {
            // Seed radio from the official-audio (ATV) id — radio from a music
            // *video* returns only videos, which we'd then filter to nothing.
            var seed: String?
            if let t = seedTrack, let vid = t.youtubeVideoID {
                seed = await officialAudioID(for: vid, title: t.title, artist: t.artist)
            }
            // No listening seed yet — steer by a preferred genre if the user set one.
            if seed == nil, let genre = ProfileStore.shared.profile.preferredGenres.randomElement() {
                seed = await seedVideoID(artist: genre, title: "songs")
            }
            if seed == nil, let topArtist, !topArtist.isEmpty {
                seed = await seedVideoID(artist: topArtist, title: "")
            }
            guard let seed else { recommendations = []; return }
            if !force, seed == recsSeed, !recommendations.isEmpty { return }
            recommendationsLoading = true
            let results = await Task.detached { Self.fetchRadio(seed) }.value
            let libIDs = Set(Library.shared.tracks.compactMap { $0.youtubeVideoID })
            let filtered = results.filter { $0.id != seed && !libIDs.contains($0.id) }
            recommendationsLoading = false
            // Only commit a non-empty result + remember the seed; a transient
            // empty fetch then retries on the next trigger instead of sticking.
            guard !filtered.isEmpty else { return }
            recommendations = filtered
            recsSeed = seed
        }
    }

    // MARK: Song trivia (Genius)

    @Published private(set) var trivia: SongTrivia?
    @Published private(set) var triviaTrackKey: String?
    @Published private(set) var triviaLoading = false
    private var triviaCache: [String: SongTrivia] = [:]

    /// Loads PER-SONG trivia (no setup needed): Wikipedia's song article, with
    /// the artist bio as a last resort. A Genius token (if set) is preferred for
    /// the richest per-song "About".
    func loadTrivia(for track: Track) {
        let key = "\(track.artist.lowercased())|\(track.title.lowercased())"
        if triviaTrackKey == key, trivia != nil || triviaLoading { return }
        triviaTrackKey = key
        if let cached = triviaCache[key] { trivia = cached; triviaLoading = false; return }
        trivia = nil
        triviaLoading = true
        let artist = track.artist, title = track.title
        let token = Settings.shared.geniusToken.trimmingCharacters(in: .whitespaces)
        Task {
            let result = await Task.detached { () -> SongTrivia? in
                if !token.isEmpty, let g = Self.fetchTrivia(artist: artist, title: title, token: token) { return g }
                if let w = Self.fetchWikipediaTrivia(artist: artist, title: title) { return w }
                return Self.fetchArtistTrivia(artist: artist)
            }.value
            guard triviaTrackKey == key else { return }
            if let result { triviaCache[key] = result }
            trivia = result
            triviaLoading = false
        }
    }

    /// Per-song trivia from Wikipedia (free, no token). Searches for the song's
    /// article, preferring titles that contain the song name, and accepts the
    /// intro extract only if it actually mentions the artist (right song).
    nonisolated private static func fetchWikipediaTrivia(artist: String, title: String) -> SongTrivia? {
        let clean = title.replacingOccurrences(of: #"\s*[\(\[].*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        func api(_ items: [URLQueryItem]) -> [String: Any]? {
            guard var c = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
            c.queryItems = [.init(name: "format", value: "json"), .init(name: "action", value: "query")] + items
            guard let u = c.url, let d = httpGET(u) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        guard let s = api([.init(name: "list", value: "search"),
                           .init(name: "srsearch", value: "\(clean) \(artist) song"),
                           .init(name: "srlimit", value: "6")]),
              let q = s["query"] as? [String: Any],
              let hits = q["search"] as? [[String: Any]] else { return nil }
        var titles = hits.compactMap { $0["title"] as? String }
        let ct = clean.lowercased()
        titles.sort { a, b in
            func score(_ x: String) -> Int {
                let xl = x.lowercased(); var s = 0
                if xl.contains(ct) { s += 3 }
                if xl.contains("song)") { s += 2 }
                if xl.contains("(song)") { s += 1 }
                return s
            }
            return score(a) > score(b)
        }
        for cand in titles.prefix(4) {
            guard let e = api([.init(name: "prop", value: "extracts"),
                               .init(name: "exintro", value: "1"),
                               .init(name: "explaintext", value: "1"),
                               .init(name: "redirects", value: "1"),
                               .init(name: "titles", value: cand)]),
                  let q2 = e["query"] as? [String: Any],
                  let pages = q2["pages"] as? [String: Any],
                  let page = pages.values.first as? [String: Any],
                  let extract = (page["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  extract.count > 40 else { continue }
            // Right song only if the intro mentions the artist.
            guard artist.isEmpty || extract.lowercased().contains(artist.lowercased()) else { continue }
            let pageTitle = (page["title"] as? String) ?? cand
            let url = "https://en.wikipedia.org/wiki/" +
                pageTitle.replacingOccurrences(of: " ", with: "_")
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            return SongTrivia(text: extract, subtitle: "", source: "Wikipedia", url: url)
        }
        return nil
    }

    /// Last-resort trivia: the artist's bio from YouTube Music (light `bio`
    /// query — no discography fetch, so it's fast).
    nonisolated private static func fetchArtistTrivia(artist: String) -> SongTrivia? {
        guard !artist.isEmpty else { return nil }
        let (data, _) = runHelper(["bio", artist])
        guard let data,
              let o = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let bio = (o["bio"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bio.isEmpty else { return nil }
        let subs = o["subscribers"] ?? ""
        return SongTrivia(text: bio, subtitle: subs.isEmpty ? "" : "\(subs) subscribers",
                          source: "", url: "")
    }

    func clearTrivia() { trivia = nil; triviaTrackKey = nil; triviaLoading = false }

    nonisolated private static func fetchTrivia(artist: String, title: String, token: String) -> SongTrivia? {
        func get(_ url: URL) -> Data? {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("Mute", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0); var out: Data?
            URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 9)
            return out
        }
        // 1) Search for the song.
        guard var c = URLComponents(string: "https://api.genius.com/search") else { return nil }
        c.queryItems = [.init(name: "q", value: "\(artist) \(title)")]
        guard let su = c.url, let sd = get(su),
              let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
              let resp = sj["response"] as? [String: Any],
              let hits = resp["hits"] as? [[String: Any]] else { return nil }
        let result = hits.lazy.compactMap { $0["result"] as? [String: Any] }.first
        guard let result, let id = result["id"] as? Int else { return nil }
        let songURL = result["url"] as? String ?? ""
        // 2) Fetch the song "About" description (plain text).
        guard let du = URL(string: "https://api.genius.com/songs/\(id)?text_format=plain"),
              let dd = get(du),
              let dj = try? JSONSerialization.jsonObject(with: dd) as? [String: Any],
              let dresp = dj["response"] as? [String: Any],
              let song = dresp["song"] as? [String: Any] else { return nil }
        let desc = ((song["description"] as? [String: Any])?["plain"] as? String) ?? ""
        let release = song["release_date_for_display"] as? String ?? ""
        let text = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "?" { return nil }
        return SongTrivia(text: text, subtitle: release, source: "Genius", url: songURL)
    }

    // MARK: Tag repair

    /// What YouTube Music knows about one video, used to write real tags onto a
    /// file that was imported from disk rather than through the download flow.
    struct SongTags: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var year: String?
        var track: Int?
        var trackTotal: Int?
        var thumb: String?
    }

    nonisolated static func songTags(for videoID: String) -> SongTags? {
        let (data, _) = runHelper(["song", videoID])
        guard let data, let tags = try? JSONDecoder().decode(SongTags.self, from: data),
              let title = tags.title, !title.isEmpty else { return nil }
        return tags
    }

    // MARK: Lyrics (timed, for Now Playing)

    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsTrackKey: String?
    @Published private(set) var lyricsLoading = false
    private var lyricsCache: [String: Lyrics] = [:]

    /// Fetches (and caches) synced lyrics for ANY track: tries YouTube's timed
    /// lyrics first (for YouTube tracks), then falls back to LRCLIB (which also
    /// covers local files), so virtually every song gets synced lyrics.
    func loadLyrics(for track: Track) {
        let key = track.youtubeVideoID
            ?? "\(track.artist.lowercased())|\(track.title.lowercased())"
        if lyricsTrackKey == key, lyrics != nil || lyricsLoading { return }
        lyricsTrackKey = key
        if let cached = lyricsCache[key] { lyrics = cached; lyricsLoading = false; return }
        lyrics = nil; lyricsLoading = true
        let videoID = track.youtubeVideoID
        let artist = track.artist, title = track.title, album = track.album, dur = track.duration
        let canYT = ready
        Task {
            let result = await Task.detached { () -> Lyrics? in
                // 1) YouTube timed lyrics (best when available).
                if canYT, let id = videoID, let yt = Self.fetchLyrics(id), yt.synced { return yt }
                // 2) LRCLIB synced lyrics (works for local files too).
                if let lrc = Self.fetchLRCLIB(artist: artist, title: title, album: album, duration: dur) { return lrc }
                // 3) YouTube plain lyrics, last resort.
                if canYT, let id = videoID, let yt = Self.fetchLyrics(id) { return yt }
                return nil
            }.value
            guard lyricsTrackKey == key else { return }
            if let result { lyricsCache[key] = result }
            lyrics = result
            lyricsLoading = false
        }
    }

    /// Clears lyrics state (e.g. when nothing is playing).
    func clearLyrics() { lyrics = nil; lyricsTrackKey = nil; lyricsLoading = false }

    nonisolated private static func fetchLyrics(_ id: String) -> Lyrics? {
        let (data, _) = runHelper(["lyrics", id])
        guard let data else { return nil }
        struct Raw: Decodable {
            struct Line: Decodable { let t: Double; let text: String }
            let lines: [Line]?
            let plain: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let lines = (raw.lines ?? []).map { LyricLine(time: $0.t / 1000.0, text: $0.text) }
        let plain = raw.plain ?? ""
        if lines.isEmpty && plain.isEmpty { return nil }
        return Lyrics(lines: lines, plain: plain)
    }

    // MARK: LRCLIB (free synced-lyrics database — covers any song)

    nonisolated private static func httpGET(_ url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mute (macOS music player)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 9)
        return out
    }

    private struct LRCRecord: Decodable { let syncedLyrics: String?; let plainLyrics: String?; let duration: Double? }

    nonisolated private static func fetchLRCLIB(artist: String, title: String, album: String, duration: TimeInterval) -> Lyrics? {
        guard !title.isEmpty else { return nil }
        // 1) Exact signature match.
        if var c = URLComponents(string: "https://lrclib.net/api/get") {
            c.queryItems = [
                .init(name: "artist_name", value: artist),
                .init(name: "track_name", value: title),
                .init(name: "album_name", value: album),
                .init(name: "duration", value: String(Int(duration.rounded()))),
            ]
            if let u = c.url, let d = httpGET(u), let r = try? JSONDecoder().decode(LRCRecord.self, from: d) {
                if let synced = r.syncedLyrics, !synced.isEmpty {
                    let lines = parseLRC(synced)
                    if !lines.isEmpty { return Lyrics(lines: lines, plain: r.plainLyrics ?? "") }
                }
            }
        }
        // 2) Search fallback — pick the closest-duration result that has synced lyrics.
        if var c = URLComponents(string: "https://lrclib.net/api/search") {
            c.queryItems = [
                .init(name: "track_name", value: title),
                .init(name: "artist_name", value: artist),
            ]
            if let u = c.url, let d = httpGET(u), let arr = try? JSONDecoder().decode([LRCRecord].self, from: d) {
                let synced = arr.filter { !($0.syncedLyrics ?? "").isEmpty }
                let best = synced.min {
                    abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
                }
                if let s = best?.syncedLyrics {
                    let lines = parseLRC(s)
                    if !lines.isEmpty { return Lyrics(lines: lines, plain: best?.plainLyrics ?? "") }
                }
                if let plain = arr.first(where: { !($0.plainLyrics ?? "").isEmpty })?.plainLyrics {
                    return Lyrics(lines: [], plain: plain)
                }
            }
        }
        return nil
    }

    /// Parses LRC text ("[mm:ss.xx] line") into timed lines (seconds). Handles
    /// multiple timestamps per line and skips metadata tags like [ar:…].
    nonisolated private static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            var idx = line.startIndex
            var times: [TimeInterval] = []
            while idx < line.endIndex, line[idx] == "[" {
                guard let close = line[idx...].firstIndex(of: "]") else { break }
                let tag = String(line[line.index(after: idx)..<close])
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    times.append(m * 60 + s)
                }
                idx = line.index(after: close)
            }
            let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    // MARK: Artist profiles (for the library Artists page)

    @Published private(set) var artistProfile: YTArtistDetail?
    @Published private(set) var artistProfileName: String?
    @Published private(set) var artistProfileLoading = false

    /// Fetches an artist's YouTube Music profile (bio + discography + top songs)
    /// by name, to enrich the library artist page. No-op when not ready/offline.
    func loadArtistProfile(name: String) {
        guard ready, online else { return }   // retried by the view when ready flips
        if artistProfileName == name, (artistProfile != nil || artistProfileLoading) { return }
        artistProfileName = name
        artistProfile = nil
        artistProfileLoading = true
        Task {
            let profile = await Task.detached { Self.fetchArtistByName(name) }.value
            guard artistProfileName == name else { return }   // user moved on
            artistProfile = profile
            artistProfileLoading = false
        }
    }

    func profile(for name: String) -> YTArtistDetail? {
        artistProfileName == name ? artistProfile : nil
    }

    // Per-artist avatar images for the Artists grid (lighter than a full profile).
    @Published private(set) var artistImages: [String: URL] = [:]
    private var artistImageInFlight: Set<String> = []

    func artistImage(for name: String) -> URL? { artistImages[name] }

    func loadArtistImage(name: String) {
        guard ready, online, artistImages[name] == nil, !artistImageInFlight.contains(name) else { return }
        artistImageInFlight.insert(name)
        Task {
            let image = await Task.detached { Self.fetchArtistImage(name) }.value
            artistImageInFlight.remove(name)
            if let image { artistImages[name] = image }
        }
    }

    nonisolated private static func fetchArtistImage(_ name: String) -> URL? {
        let (data, _) = runHelper(["artistimage", name])
        guard let data, let p = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return url(p["thumb"])
    }

    // Resolved stream URLs are valid for hours; cache them so replays and
    // prefetched next-tracks start instantly instead of re-running yt-dlp.
    private var streamURLCache: [String: (url: URL, at: Date)] = [:]
    private static let streamURLTTL: TimeInterval = 5 * 3600

    func cachedStreamURL(videoId: String) -> URL? {
        guard let e = streamURLCache[videoId], Date().timeIntervalSince(e.at) < Self.streamURLTTL else { return nil }
        return e.url
    }

    /// Resolves a videoId to a playable audio URL (called by the Player), using
    /// the cache when fresh.
    func resolveStreamURL(videoId: String) async -> URL? {
        if let cached = cachedStreamURL(videoId: videoId) { return cached }
        guard let ytdlp = path(for: "yt-dlp") else { return nil }
        let ffmpeg = path(for: "ffmpeg")
        let url = await Task.detached { Self.resolveStream(ytdlp: ytdlp, ffmpeg: ffmpeg, id: videoId) }.value
        if let url { streamURLCache[videoId] = (url, Date()) }
        return url
    }

    /// Resolves (and caches) a stream URL ahead of time — used to prefetch the
    /// next track so it starts with no delay.
    func prefetchStreamURL(videoId: String) {
        guard ready, online, cachedStreamURL(videoId: videoId) == nil else { return }
        Task { _ = await resolveStreamURL(videoId: videoId) }
    }

    // MARK: Official-audio canonicalization

    // Some library entries point at a music *video* (or live/lyric upload) whose
    // audio differs from the studio master. We map those to YouTube Music's
    // official-audio "art track" (ATV) so playback and radio use clean audio.
    // Persisted so the title→ATV lookup only happens once per track, ever.
    private lazy var atvMap: [String: String] = Self.loadATVMap()

    private static var atvMapPath: String { appSupportDir.appendingPathComponent("atvmap.json").path }
    private static func loadATVMap() -> [String: String] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: atvMapPath)),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }
    private func saveATVMap() {
        if let d = try? JSONEncoder().encode(atvMap) {
            try? d.write(to: URL(fileURLWithPath: Self.atvMapPath))
        }
    }

    /// Returns the official-audio (ATV) videoId for a track, falling back to the
    /// original id when no confident match exists. Cached + persisted.
    func officialAudioID(for videoId: String, title: String, artist: String) async -> String {
        if let mapped = atvMap[videoId] { return mapped }
        guard ready, online, !title.isEmpty else { return videoId }
        let result = await Task.detached { () -> String in
            let q = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
            let (data, _) = Self.runHelper(["search", q])
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = obj["songs"] as? [[String: Any]], !songs.isEmpty else { return videoId }
            // The "songs" filter only returns ATV tracks; pick the first whose
            // title (and artist, when known) matches, so we never swap in a
            // different song. Otherwise keep the original id.
            let want = Self.norm(title), wantArtist = Self.norm(artist)
            for s in songs {
                guard let id = s["id"] as? String, let t = s["title"] as? String else { continue }
                let tn = Self.norm(t), an = Self.norm((s["artist"] as? String) ?? "")
                let titleOK = tn == want || tn.contains(want) || want.contains(tn)
                let artistOK = wantArtist.isEmpty || an.contains(wantArtist) || wantArtist.contains(an)
                if titleOK && artistOK { return id }
            }
            return videoId
        }.value
        atvMap[videoId] = result
        saveATVMap()
        return result
    }

    /// Lowercased, diacritic- and punctuation-stripped key for fuzzy matching.
    nonisolated static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// AVFoundation can't decode Opus/WebM, so force an m4a/mp4 stream.
    nonisolated private static func resolveStream(ytdlp: String, ffmpeg: String?, id: String) -> URL? {
        var args = ["--no-warnings", "-f", "ba[ext=m4a]/ba[ext=mp4]/b[ext=mp4]/b",
                    "-g", "https://www.youtube.com/watch?v=\(id)"]
        if let ffmpeg { args = ["--ffmpeg-location", ffmpeg] + args }
        let r = runSync(ytdlp, args)
        guard r.code == 0 else { return nil }
        let line = r.out.split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("http") }
        return line.flatMap { URL(string: $0) }
    }

    // MARK: Download

    func download(_ result: YTResult) {
        if case .downloading = downloads[result.id] { return }
        guard online else { downloads[result.id] = .failed("Offline"); return }
        Task { await performDownload(result, album: nil, albumArtist: nil, trackNumber: nil, cover: result.cover) }
    }

    /// Downloads every track of an album into the library as a proper album
    /// (album name + artist + track numbers), sequentially.
    func downloadAlbum(_ detail: YTAlbumDetail) {
        guard online else { return }
        Task {
            for (i, track) in detail.tracks.enumerated() {
                if isDownloaded(track.id) { continue }
                if case .downloading = downloads[track.id] { continue }
                await performDownload(track, album: detail.title, albumArtist: detail.artist,
                                      trackNumber: track.trackNumber ?? (i + 1), cover: detail.thumb)
            }
        }
    }

    /// Downloads a single album track with the album's name, artist and track
    /// number, so it forms a proper album in the local library.
    func downloadTrack(_ result: YTResult, inAlbum detail: YTAlbumDetail) {
        if case .downloading = downloads[result.id] { return }
        if isDownloaded(result.id) { return }
        guard online else { downloads[result.id] = .failed("Offline"); return }
        let trackNumber = result.trackNumber ?? detail.tracks.firstIndex(of: result).map { $0 + 1 }
        Task { await performDownload(result, album: detail.title, albumArtist: detail.artist,
                                     trackNumber: trackNumber, cover: detail.thumb) }
    }

    var albumDownloadInProgress: Bool {
        guard let tracks = albumDetail?.tracks else { return false }
        return tracks.contains { if case .downloading = downloads[$0.id] { return true } else { return false } }
    }

    private func performDownload(_ result: YTResult, album: String?, albumArtist: String?,
                                 trackNumber: Int?, cover: URL?) async {
        guard let ytdlp = path(for: "yt-dlp") else { downloads[result.id] = .failed("yt-dlp missing"); return }
        let ffmpeg = path(for: "ffmpeg")
        downloads[result.id] = .downloading(-1)
        let outcome = await runDownload(ytdlp: ytdlp, ffmpeg: ffmpeg, result: result)
        switch outcome {
        case .success(let fileURL):
            let added = await Library.shared.importFiles([fileURL])
            if let track = added.first {
                Library.shared.updateTrackTags(id: track.id,
                    edit: TagEdit(title: result.title, artist: result.artist,
                                  album: album ?? "YouTube", albumArtist: albumArtist ?? "",
                                  genre: "", year: nil, trackNumber: trackNumber))
                // Use the exact square YouTube Music cover (not the 16:9 video thumb).
                let coverURL = cover ?? result.cover
                if let coverURL, let data = await Task.detached(operation: { try? Data(contentsOf: coverURL) }).value {
                    Library.shared.setTrackArtwork(track.id, data: data)
                }
            }
            downloads[result.id] = .done
        case .failure(let error):
            downloads[result.id] = .failed(error.localizedDescription)
        }
    }

    private func runDownload(ytdlp: String, ffmpeg: String?, result: YTResult) async -> Result<URL, YTError> {
        let id = result.id
        let template = Self.downloadDir.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path
        var args = ["--no-playlist", "--newline", "--no-warnings",
                    "-f", "ba[ext=m4a]/ba",
                    "-o", template,
                    "https://www.youtube.com/watch?v=\(id)"]
        if let ffmpeg {
            args.insert(contentsOf: ["--ffmpeg-location", ffmpeg,
                                     "--embed-metadata", "--embed-thumbnail",
                                     "--convert-thumbnails", "jpg"], at: 0)
        }
        let code = await runStreaming(ytdlp, args) { [weak self] chunk in
            guard let self, case .downloading = self.downloads[id] else { return }
            if let pct = Self.parseProgress(chunk) { self.downloads[id] = .downloading(pct) }
        }
        guard code == 0 else { return .failure(YTError(message: "Download failed (yt-dlp exited \(code)).")) }
        guard let file = Self.downloadedFile(forID: id) else { return .failure(YTError(message: "Downloaded file not found.")) }
        return .success(file)
    }

    func isDownloaded(_ id: String) -> Bool { downloadedTrack(for: id) != nil }

    func downloadedTrack(for id: String) -> Track? {
        let marker = "[\(id)]"
        return Library.shared.tracks.first {
            $0.path.contains(marker) && $0.path.contains("/Mute/YouTube/")
        }
    }

    func playDownloaded(_ result: YTResult) {
        guard let track = downloadedTrack(for: result.id),
              let index = Library.shared.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        Player.shared.play(queue: [Library.shared.tracks[index]], at: 0)
    }

    nonisolated private static func downloadedFile(forID id: String) -> URL? {
        let marker = "[\(id)]"
        let items = (try? FileManager.default.contentsOfDirectory(
            at: downloadDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.lastPathComponent.contains(marker) && Library.isAudioFile($0) }
            .max { (modDate($0) ?? .distantPast) < (modDate($1) ?? .distantPast) }
    }

    // MARK: Install (Homebrew + venv)

    func install() {
        guard !installing else { return }
        installing = true
        installLog = ""
        Task {
            if Self.locate("yt-dlp") == nil || Self.locate("ffmpeg") == nil {
                if let brew = Self.locate("brew") {
                    appendLog("Installing yt-dlp and ffmpeg with Homebrew…\n\n")
                    _ = await runStreaming(brew, ["install", "yt-dlp", "ffmpeg"]) { [weak self] c in self?.appendLog(c) }
                } else {
                    appendLog("Homebrew not found — install it from https://brew.sh, then run:\n  brew install yt-dlp ffmpeg\n")
                }
            }
            if !Self.ytmusicReady() {
                appendLog("\nSetting up the music library (ytmusicapi)…\n\n")
                let venv = Self.appSupportDir.appendingPathComponent("pyenv").path
                _ = await runStreaming("/usr/bin/python3", ["-m", "venv", venv]) { [weak self] c in self?.appendLog(c) }
                let pip = Self.appSupportDir.appendingPathComponent("pyenv/bin/pip").path
                _ = await runStreaming(pip, ["install", "--upgrade", "ytmusicapi"]) { [weak self] c in self?.appendLog(c) }
            }
            Self.ensureHelper()
            appendLog("\n✓ Setup complete.")
            installing = false
            refreshTool()
        }
    }

    private func appendLog(_ chunk: String) {
        installLog += chunk
        if installLog.count > 8000 { installLog = "…\n" + installLog.suffix(6000) }
    }

    // MARK: ytmusicapi helper bridge

    nonisolated static var helperPath: String { appSupportDir.appendingPathComponent("ytmusic_helper.py").path }

    /// Writes the Python helper to disk (idempotent — keeps it current).
    nonisolated static func ensureHelper() {
        try? helperSource.data(using: .utf8)?.write(to: URL(fileURLWithPath: helperPath))
    }

    nonisolated private static func runHelper(_ args: [String]) -> (data: Data?, error: String?) {
        guard let py = venvPython() else { return (nil, "Music library not installed.") }
        ensureHelper()
        let r = runSync(py, [helperPath] + args)
        guard r.code == 0, let data = r.out.data(using: .utf8), !data.isEmpty else {
            return (nil, firstLine(r.err) ?? "Lookup failed.")
        }
        return (data, nil)
    }

    nonisolated static func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private struct SearchJSON: Decodable {
        struct Artist: Decodable { let id: String; let name: String; let thumb: String? }
        struct Album: Decodable { let id: String; let title: String; let artist: String; let year: String; let kind: String; let thumb: String? }
        struct Song: Decodable { let id: String; let title: String; let artist: String; let duration: Double; let thumb: String? }
        let artists: [Artist]?; let albums: [Album]?; let songs: [Song]?; let error: String?
    }
    private struct ArtistJSON: Decodable {
        struct Album: Decodable { let id: String; let title: String; let artist: String; let year: String; let kind: String; let thumb: String? }
        struct Song: Decodable { let id: String; let title: String; let artist: String; let duration: Double; let thumb: String? }
        struct Related: Decodable { let id: String; let name: String; let thumb: String? }
        let name: String?; let thumb: String?; let bio: String?; let subscribers: String?
        let albums: [Album]?; let singles: [Album]?; let songs: [Song]?; let related: [Related]?; let error: String?
    }
    private struct AlbumJSON: Decodable {
        struct Track: Decodable { let id: String; let title: String; let artist: String; let duration: Double; let track: Int? }
        let title: String?; let artist: String?; let year: String?; let thumb: String?; let tracks: [Track]?; let error: String?
    }

    nonisolated private static func fetchSearch(_ query: String)
        -> Result<(artists: [YTArtist], albums: [YTAlbum], songs: [YTResult]), YTError> {
        let (data, err) = runHelper(["search", query])
        guard let data else { return .failure(YTError(message: err ?? "Search failed.")) }
        guard let p = try? JSONDecoder().decode(SearchJSON.self, from: data) else {
            return .failure(YTError(message: "Couldn’t read the search results."))
        }
        if let e = p.error { return .failure(YTError(message: e)) }
        let artists = (p.artists ?? []).map { YTArtist(id: $0.id, name: $0.name, thumb: url($0.thumb)) }
        let albums = (p.albums ?? []).map {
            YTAlbum(id: $0.id, title: $0.title, artist: $0.artist, year: $0.year, kind: $0.kind, thumb: url($0.thumb))
        }
        let songs = (p.songs ?? []).map {
            YTResult(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration, cover: url($0.thumb))
        }
        return .success((artists, albums, songs))
    }

    nonisolated private static func fetchArtist(_ id: String) -> YTArtistDetail? {
        decodeArtist(runHelper(["artist", id]).data)
    }

    /// Looks up an artist's full YouTube Music profile by name (search → profile).
    nonisolated private static func fetchArtistByName(_ name: String) -> YTArtistDetail? {
        decodeArtist(runHelper(["artistsearch", name]).data)
    }

    nonisolated private static func decodeArtist(_ data: Data?) -> YTArtistDetail? {
        guard let data, let p = try? JSONDecoder().decode(ArtistJSON.self, from: data), p.error == nil else { return nil }
        func map(_ a: [ArtistJSON.Album]?) -> [YTAlbum] {
            (a ?? []).map { YTAlbum(id: $0.id, title: $0.title, artist: $0.artist, year: $0.year, kind: $0.kind, thumb: url($0.thumb)) }
        }
        let songs = (p.songs ?? []).map {
            YTResult(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration, cover: url($0.thumb))
        }
        let related = (p.related ?? []).map { YTArtist(id: $0.id, name: $0.name, thumb: url($0.thumb)) }
        return YTArtistDetail(name: p.name ?? "", thumb: url(p.thumb), bio: p.bio ?? "",
                              subscribers: p.subscribers ?? "", albums: map(p.albums),
                              singles: map(p.singles), topSongs: songs, related: related)
    }

    nonisolated private static func fetchAlbum(_ id: String) -> YTAlbumDetail? {
        let (data, _) = runHelper(["album", id])
        guard let data, let p = try? JSONDecoder().decode(AlbumJSON.self, from: data), p.error == nil else { return nil }
        let tracks = (p.tracks ?? []).map {
            YTResult(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration, trackNumber: $0.track)
        }
        return YTAlbumDetail(id: id, title: p.title ?? "", artist: p.artist ?? "",
                             year: p.year ?? "", thumb: url(p.thumb), tracks: tracks)
    }

    // MARK: Process helpers

    nonisolated static func runSync(_ launch: String, _ args: [String]) -> (out: String, err: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        proc.environment = environment()
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "mute.proc.read", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try proc.run() } catch { return ("", error.localizedDescription, -1) }
        proc.waitUntilExit()
        group.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), proc.terminationStatus)
    }

    private func runStreaming(_ launch: String, _ args: [String],
                              onChunk: @escaping @MainActor (String) -> Void) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launch)
            proc.arguments = args
            proc.environment = Self.environment()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
                Task { @MainActor in onChunk(s) }
            }
            proc.terminationHandler = { p in
                handle.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run() } catch {
                handle.readabilityHandler = nil
                cont.resume(returning: -1)
            }
        }
    }

    nonisolated private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:" + (env["PATH"] ?? "")
        return env
    }

    nonisolated private static func parseProgress(_ s: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = re.matches(in: s, range: range).last,
              let r = Range(match.range(at: 1), in: s),
              let pct = Double(s[r]) else { return nil }
        return min(1, max(0, pct / 100))
    }

    nonisolated private static func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Embedded Python helper (ytmusicapi)

extension YouTubeService {
    /// Runs in the venv. Prints a single JSON object on stdout; warnings go to
    /// stderr. Commands: `search <q>`, `artist <browseId>`, `album <browseId>`.
    nonisolated static let helperSource = """
    import sys, json, re, warnings
    warnings.filterwarnings("ignore")
    try:
        from ytmusicapi import YTMusic
    except Exception as e:
        print(json.dumps({"error": "ytmusicapi not available: %s" % e}))
        sys.exit(0)

    def thumb(o):
        # watch-playlist/radio tracks use "thumbnail" (singular); most others use "thumbnails".
        ts = o.get("thumbnails") or o.get("thumbnail") or []
        if not ts:
            return None
        url = ts[-1].get("url")
        # Cover URLs carry their size as "=w120-h120-..."; bump it up so the
        # now-playing art isn't a blurry upscale of a tiny thumbnail.
        if url:
            url = re.sub(r"=w\\d+-h\\d+", "=w544-h544", url)
        return url

    def first_artist(o):
        a = o.get("artists") or []
        if a and a[0].get("name"):
            return a[0]["name"]
        return o.get("artist") or ""

    def year_str(v):
        s = str(v) if v is not None else ""
        return s if s.isdigit() else ""

    def album_obj(r, artist, kind):
        return {"id": r.get("browseId") or "", "title": r.get("title") or "",
                "artist": artist, "year": year_str(r.get("year")),
                "kind": kind, "thumb": thumb(r)}

    def main():
        yt = YTMusic()
        cmd = sys.argv[1]
        if cmd == "search":
            q = sys.argv[2]
            out = {"artists": [], "albums": [], "songs": []}
            try:
                for r in yt.search(q, filter="artists")[:8]:
                    if r.get("browseId"):
                        out["artists"].append({"id": r["browseId"], "name": r.get("artist") or "", "thumb": thumb(r)})
            except Exception:
                pass
            try:
                for r in yt.search(q, filter="albums")[:12]:
                    if r.get("browseId"):
                        out["albums"].append(album_obj(r, first_artist(r), r.get("type") or "Album"))
            except Exception:
                pass
            try:
                for r in yt.search(q, filter="songs")[:20]:
                    if r.get("videoId"):
                        out["songs"].append({"id": r["videoId"], "title": r.get("title") or "",
                                             "artist": first_artist(r), "duration": r.get("duration_seconds") or 0,
                                             "thumb": thumb(r)})
            except Exception:
                pass
            print(json.dumps(out))
        elif cmd == "artistimage":
            t = None
            for r in yt.search(sys.argv[2], filter="artists"):
                if r.get("browseId"):
                    t = thumb(r)
                    break
            print(json.dumps({"thumb": t or ""}))
        elif cmd == "artist" or cmd == "artistsearch":
            bid = sys.argv[2]
            if cmd == "artistsearch":
                bid = None
                for r in yt.search(sys.argv[2], filter="artists"):
                    if r.get("browseId"):
                        bid = r["browseId"]
                        break
                if not bid:
                    print(json.dumps({"error": "not found"}))
                    return
            a = yt.get_artist(bid)
            name = a.get("name") or ""
            def section(key, kind):
                sec = a.get(key) or {}
                res = sec.get("results") or []
                # get_artist returns only a preview of each section; when it
                # carries a browseId + params, fetch the COMPLETE list so no
                # albums/singles go missing on the artist page.
                if sec.get("browseId") and sec.get("params"):
                    try:
                        res = yt.get_artist_albums(sec["browseId"], sec["params"])
                    except Exception:
                        pass
                seen = set()
                out_list = []
                for r in res:
                    b = r.get("browseId")
                    if b and b not in seen:
                        seen.add(b)
                        out_list.append(album_obj(r, name, kind))
                return out_list
            songs = []
            for r in ((a.get("songs") or {}).get("results") or []):
                if r.get("videoId"):
                    songs.append({"id": r["videoId"], "title": r.get("title") or "",
                                  "artist": first_artist(r), "duration": r.get("duration_seconds") or 0,
                                  "thumb": thumb(r)})
            # Genre-similar artists (for taste-based discovery).
            related = []
            for r in ((a.get("related") or {}).get("results") or []):
                b = r.get("browseId")
                if b:
                    related.append({"id": b, "name": r.get("title") or "", "thumb": thumb(r)})
            out = {"id": bid, "name": name, "thumb": thumb(a),
                   "bio": a.get("description") or "",
                   "subscribers": a.get("subscribers") or "",
                   "albums": section("albums", "Album"), "singles": section("singles", "Single"),
                   "songs": songs, "related": related}
            print(json.dumps(out))
        elif cmd == "album":
            a = yt.get_album(sys.argv[2])
            tracks = []
            for i, t in enumerate(a.get("tracks") or [], 1):
                if not t.get("videoId"):
                    continue
                tn = t.get("trackNumber")
                tracks.append({"id": t["videoId"], "title": t.get("title") or "",
                               "artist": first_artist(t), "duration": t.get("duration_seconds") or 0,
                               "track": tn if isinstance(tn, int) else i})
            out = {"title": a.get("title") or "", "artist": first_artist(a),
                   "year": year_str(a.get("year")), "thumb": thumb(a), "tracks": tracks}
            print(json.dumps(out))
        elif cmd == "song":
            # Resolving a downloaded file back to its catalogue entry.
            # get_watch_playlist would be the direct route but throws KeyError
            # 'endpoint' for many videos, and a file downloaded from a regular
            # YouTube upload has a different videoId from the YT Music track
            # anyway — so match on the title and artist the video itself
            # reports, which are already clean ("Antisocial", "Anthrax") where
            # the filename is not ("Anthrax - Antisocial (Official Video)").
            vid = sys.argv[2]
            out = {}
            try:
                wp = yt.get_watch_playlist(vid)
                t = (wp.get("tracks") or [{}])[0]
                alb = t.get("album") or {}
                if not isinstance(alb, dict):
                    alb = {"name": alb}
                out = {"title": t.get("title") or "", "artist": first_artist(t),
                       "album": alb.get("name") or "", "albumId": alb.get("id") or "",
                       "thumb": thumb(t)}
            except Exception:
                pass
            if not out.get("title"):
                try:
                    vd = (yt.get_song(vid) or {}).get("videoDetails") or {}
                    out = {"title": vd.get("title") or "", "artist": vd.get("author") or "",
                           "album": "", "albumId": "", "thumb": None}
                except Exception:
                    pass

            def norm(x):
                return re.sub(r"[^a-z0-9]", "", (x or "").lower())

            def clean_title(t):
                # YouTube uploads carry furniture the catalogue never has:
                # "Get Lucky (Official Audio) ft. Pharrell Williams" is just
                # "Get Lucky" as far as YT Music is concerned. Written without
                # backslashes on purpose — this whole file is a Swift string
                # literal, where a backslash-paren starts an interpolation.
                t = t or ""
                noise = "[([][ ]*(official[ ]*)?(music[ ]*)?(video|audio|lyrics?|visualizer|hd|hq|4k)[ ]*[])]"
                t = re.sub(noise, " ", t, flags=re.I)
                # The leading [ ]+ is load-bearing: without it this eats the
                # "ft" inside "Daft Punk" and leaves "Da".
                t = re.sub("[ ]+[([]?[ ]*(ft[.]?|feat[.]?)[ ][^])]*[])]?", " ", t, flags=re.I)
                t = re.sub("[ ]*-[ ]*(official[ ]*)?(music[ ]*)?(video|audio)[ ]*$", " ", t, flags=re.I)
                t = re.sub("[ ]{2,}", " ", t)
                return t.strip(" -" + chr(8211) + chr(8212))

            if out.get("title"):
                out["title"] = clean_title(out["title"]) or out["title"]

            # Find the catalogue entry, which is what carries the album.
            if out.get("title") and not out.get("album"):
                want, artist = norm(out["title"]), norm(out.get("artist"))
                try:
                    hits = yt.search("%s %s" % (out["title"], out.get("artist") or ""),
                                     filter="songs", limit=8) or []
                except Exception:
                    hits = []
                best = None
                for h in hits:
                    alb = h.get("album") or {}
                    if not isinstance(alb, dict) or not alb.get("name"):
                        continue
                    # The catalogue has its own furniture — "Get Lucky (feat.
                    # Pharrell Williams)" — so clean both sides before comparing.
                    if norm(clean_title(h.get("title"))) != want:
                        continue
                    # Live and anniversary re-recordings share the title; prefer
                    # a hit whose artist matches too, and take the first one.
                    if artist and artist not in norm(first_artist(h)):
                        continue
                    best = h
                    break
                if best:
                    alb = best["album"]
                    out["album"] = alb.get("name") or ""
                    out["albumId"] = alb.get("id") or ""
                    if not out.get("thumb"):
                        out["thumb"] = thumb(best)

            # The album gives the year, the album artist and the track number.
            if out.get("albumId"):
                try:
                    a = yt.get_album(out["albumId"])
                    out["year"] = year_str(a.get("year"))
                    out["albumArtist"] = first_artist(a)
                    if not out.get("thumb"):
                        out["thumb"] = thumb(a)
                    want = norm(out.get("title"))
                    for i, tr in enumerate(a.get("tracks") or [], 1):
                        if norm(tr.get("title")) == want:
                            tn = tr.get("trackNumber")
                            out["track"] = tn if isinstance(tn, int) else i
                            out["trackTotal"] = len(a.get("tracks") or [])
                            break
                except Exception:
                    pass
            print(json.dumps(out))
        elif cmd == "lyrics":
            vid = sys.argv[2]
            out = {"lines": [], "plain": ""}
            try:
                wp = yt.get_watch_playlist(vid)
                bid = wp.get("lyrics")
                if bid:
                    try:
                        ly = yt.get_lyrics(bid, timestamps=True)
                        lines = ly.get("lyrics")
                        if isinstance(lines, list):
                            for ln in lines:
                                st = getattr(ln, "start_time", None)
                                tx = getattr(ln, "text", None)
                                if tx is not None and st is not None:
                                    out["lines"].append({"t": st, "text": tx})
                        elif isinstance(lines, str):
                            out["plain"] = lines
                    except Exception:
                        ly = yt.get_lyrics(bid)
                        out["plain"] = ly.get("lyrics") or ""
            except Exception:
                pass
            print(json.dumps(out))
        elif cmd == "bio":
            bid = None
            for r in yt.search(sys.argv[2], filter="artists"):
                if r.get("browseId"):
                    bid = r["browseId"]
                    break
            out = {"name": "", "bio": "", "subscribers": ""}
            if bid:
                try:
                    a = yt.get_artist(bid)
                    out = {"name": a.get("name") or "",
                           "bio": a.get("description") or "",
                           "subscribers": a.get("subscribers") or ""}
                except Exception:
                    pass
            print(json.dumps(out))
        elif cmd == "radio":
            vid = sys.argv[2]
            def _sec(s):
                try:
                    acc = 0
                    for p in str(s).split(":"):
                        acc = acc * 60 + int(p)
                    return acc
                except Exception:
                    return 0
            def _collect(wp):
                r = []
                for t in (wp.get("tracks") or []):
                    if t.get("videoId"):
                        r.append({"id": t["videoId"], "title": t.get("title") or "",
                                  "artist": first_artist(t),
                                  "duration": t.get("duration_seconds") or _sec(t.get("length")),
                                  "type": t.get("videoType") or "",
                                  "thumb": thumb(t)})
                return r
            # Only the radio endpoints return official-audio tracks (ATV) with
            # album-art covers; the plain watch-playlist returns music *videos*,
            # so it's intentionally excluded. get_watch_playlist intermittently
            # throws while parsing the related tab, so retry each.
            def _has_atv(items):
                return any(t.get("type") == "MUSIC_VIDEO_TYPE_ATV" for t in items)
            attempts = [
                lambda: yt.get_watch_playlist(videoId=vid, radio=True, limit=40),
                lambda: yt.get_watch_playlist(playlistId="RDAMVM" + vid, limit=40),
            ]
            out = []
            for fn in attempts:
                for _ in range(3):
                    try:
                        cur = _collect(fn())
                    except Exception:
                        cur = []
                    if _has_atv(cur):
                        out = cur
                        break
                    if cur and not out:
                        out = cur
                if _has_atv(out):
                    break
            print(json.dumps(out))
        elif cmd == "explore":
            # New-release ALBUMS (openable) + a few featured playlists, from the
            # region's YT Music home feed.
            out = {"newAlbums": []}
            try:
                home = yt.get_home(limit=10)
                seen = set()
                for sec in home:
                    if "new release" not in (sec.get("title") or "").lower():
                        continue
                    for r in (sec.get("contents") or []):
                        bid = r.get("browseId") or ""
                        if not bid.startswith("MPRE") or bid in seen:
                            continue
                        seen.add(bid)
                        arts = r.get("artists") or []
                        artist = arts[0]["name"] if arts and arts[0].get("name") else (r.get("subtitle") or "")
                        out["newAlbums"].append({"id": bid, "title": r.get("title") or "",
                                                 "artist": artist, "year": "",
                                                 "kind": "Album", "thumb": thumb(r)})
            except Exception as e:
                out["error"] = str(e)
            print(json.dumps(out))
        else:
            print(json.dumps({"error": "unknown command"}))

    try:
        main()
    except Exception as e:
        print(json.dumps({"error": str(e)}))
    """
}
