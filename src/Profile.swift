import SwiftUI
import AppKit

extension Notification.Name {
    static let openSettings = Notification.Name("MuteOpenSettings")
}

// MARK: - User profile (local; designed to sync to a backend later)

struct UserProfile: Codable {
    var displayName: String = NSFullUserName().isEmpty ? "You" : NSFullUserName()
    var bio: String = ""
    var avatarFile: String?          // filename inside the Profile dir
    var joinDate: Date = Date()
    var isPrivate: Bool = false
    var preferredGenres: [String] = []
    var explicitFilter: Bool = false
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profile: UserProfile { didSet { save() } }
    private var avatarCache: NSImage?

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mute").appendingPathComponent("Profile")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var fileURL: URL { dir.appendingPathComponent("profile.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let p = try? JSONDecoder().decode(UserProfile.self, from: d) {
            profile = p
        } else {
            profile = UserProfile()          // first run → joinDate = now
            save()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(profile) { try? d.write(to: Self.fileURL) }
    }

    // Avatar I/O (stored as a file so the JSON stays small).
    var avatar: NSImage? {
        if let avatarCache { return avatarCache }
        guard let name = profile.avatarFile,
              let img = NSImage(contentsOf: Self.dir.appendingPathComponent(name)) else { return nil }
        avatarCache = img
        return img
    }

    func setAvatar(_ data: Data) {
        let name = "avatar_\(UUID().uuidString).png"
        let url = Self.dir.appendingPathComponent(name)
        guard (try? data.write(to: url)) != nil else { return }
        if let old = profile.avatarFile { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(old)) }
        avatarCache = NSImage(data: data)
        profile.avatarFile = name
    }

    func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            setAvatar(data)
        }
    }
}

// MARK: - Listening statistics

enum StatRange: String, CaseIterable, Identifiable {
    case week = "Last Week", month = "Last Month", all = "All Time"
    var id: String { rawValue }
    var cutoff: Date? {
        switch self {
        case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all:   return nil
        }
    }
}

struct TrackStat: Identifiable {
    let id: String          // path
    let title: String, artist: String
    let plays: Int
    let artworkURL: String?
    let videoID: String?
}

/// Pure stats derived from the play history. `durations` maps a path → seconds
/// for library tracks (history events also carry their own duration now).
struct StatsEngine {
    let history: [PlayEvent]
    let durations: [String: Double]

    private func events(in r: StatRange) -> [PlayEvent] {
        guard let c = r.cutoff else { return history }
        return history.filter { $0.date >= c }
    }

    private func seconds(_ e: PlayEvent) -> Double {
        e.duration ?? durations[e.path] ?? 210      // ~3.5 min average fallback
    }

    func totalSeconds(in r: StatRange) -> Double { events(in: r).reduce(0) { $0 + seconds($1) } }
    func totalPlays(in r: StatRange) -> Int { events(in: r).count }

    func topArtists(in r: StatRange, limit: Int = 10) -> [(name: String, plays: Int)] {
        var counts: [String: Int] = [:]
        for e in events(in: r) where !e.artist.isEmpty { counts[e.artist, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func topTracks(in r: StatRange, limit: Int = 10) -> [TrackStat] {
        var counts: [String: Int] = [:]
        var meta: [String: PlayEvent] = [:]
        for e in events(in: r) { counts[e.path, default: 0] += 1; meta[e.path] = e }
        return counts.sorted { $0.value > $1.value }.prefix(limit).compactMap { kv in
            guard let e = meta[kv.key] else { return nil }
            return TrackStat(id: e.path, title: e.title, artist: e.artist, plays: kv.value,
                             artworkURL: e.artworkURL, videoID: e.videoID)
        }
    }

    /// Consecutive days (ending today or yesterday) that have at least one play.
    func streak() -> Int {
        let cal = Calendar.current
        let days = Set(history.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) {                       // allow the streak to end yesterday
            guard let y = cal.date(byAdding: .day, value: -1, to: day), days.contains(y) else { return 0 }
            day = y
        }
        var n = 0
        while days.contains(day) {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    /// Plays that happened between midnight and 4am (for the Night Owl badge).
    func nightOwlPlays() -> Int {
        let cal = Calendar.current
        return history.filter { (0..<4).contains(cal.component(.hour, from: $0.date)) }.count
    }
}

// MARK: - Gamification

struct LevelInfo {
    let level: Int
    let xp: Int               // total xp
    let intoLevel: Int        // xp accrued within the current level
    let span: Int             // xp needed to clear the current level
    var fraction: Double { span > 0 ? Double(intoLevel) / Double(span) : 0 }
}

struct Badge: Identifiable {
    let id: String
    let title: String, detail: String, symbol: String
    let earned: Bool
}

enum Gamification {
    /// XP = 10 per play + 1 per listening minute. Each level n costs n*150 xp.
    static func level(plays: Int, minutes: Int) -> LevelInfo {
        let xp = plays * 10 + minutes
        var level = 1, remaining = xp, span = 150
        while remaining >= span { remaining -= span; level += 1; span = level * 150 }
        return LevelInfo(level: level, xp: xp, intoLevel: remaining, span: span)
    }

    static func badges(plays: Int, genres: Int, streak: Int,
                       nightOwl: Int, minutes: Int, favorites: Int) -> [Badge] {
        func b(_ id: String, _ t: String, _ d: String, _ s: String, _ ok: Bool) -> Badge {
            Badge(id: id, title: t, detail: d, symbol: s, earned: ok)
        }
        return [
            b("first",  "First Play",     "Played your first track",        "play.circle.fill",        plays >= 1),
            b("100",    "Getting Going",  "100 tracks played",              "music.note",              plays >= 100),
            b("1000",   "Audiophile",     "1,000 tracks played",            "headphones",              plays >= 1000),
            b("genres", "Genre Explorer", "Listened across 10 genres",      "square.grid.3x3.fill",    genres >= 10),
            b("owl",    "Night Owl",      "Listened after midnight",        "moon.stars.fill",         nightOwl >= 1),
            b("streak", "On Fire",        "7-day listening streak",         "flame.fill",              streak >= 7),
            b("month",  "Devoted",        "30-day listening streak",        "calendar",                streak >= 30),
            b("hours",  "Marathon",       "1,000 minutes listened",         "stopwatch.fill",          minutes >= 1000),
            b("loved",  "Curator",        "Liked 20 songs",                 "heart.fill",              favorites >= 20),
        ]
    }
}

// MARK: - Genre inference (from YouTube Music artist bios)

@MainActor
final class GenreService: ObservableObject {
    static let shared = GenreService()

    @Published private(set) var genreByArtist: [String: String] = GenreService.load()
    private var inFlight: Set<String> = []

    // Broad genres, each with bio keywords. First match (top-to-bottom) wins, so
    // list more specific phrases first.
    private static let table: [(label: String, keys: [String])] = [
        ("Hip-Hop",    ["hip hop", "hip-hop", "rapper", " rap ", "trap"]),
        ("R&B",        ["r&b", "rnb", "rhythm and blues", "contemporary r&b"]),
        ("K-Pop",      ["k-pop", "kpop", "korean"]),
        ("Metal",      ["metal", "metalcore", "deathcore", "thrash"]),
        ("Punk",       ["punk", "hardcore"]),
        ("Rock",       ["rock band", " rock ", "rock music", "grunge"]),
        ("Electronic", ["electronic", "edm", "house music", "techno", "dubstep", "trance", "drum and bass", "dnb", "synth"]),
        ("Pop",        ["pop singer", "pop music", "pop group", " pop ", "synth-pop", "pop rock"]),
        ("Jazz",       ["jazz"]),
        ("Classical",  ["classical", "orchestra", "composer", "symphony"]),
        ("Country",    ["country music", "country singer", " country "]),
        ("Folk",       ["folk", "singer-songwriter", "acoustic"]),
        ("Soul",       ["soul music", " soul ", "motown"]),
        ("Funk",       ["funk"]),
        ("Reggae",     ["reggae", "dancehall", "ska"]),
        ("Blues",      ["blues"]),
        ("Indie",      ["indie"]),
        ("Latin",      ["latin", "reggaeton", "salsa", "bachata"]),
        ("Alternative",["alternative"]),
    ]

    static func genre(from bio: String) -> String? {
        let b = " " + bio.lowercased() + " "
        for entry in table where entry.keys.contains(where: { b.contains($0) }) { return entry.label }
        return nil
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mute")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("genres.json")
    }
    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(genreByArtist) { try? d.write(to: Self.fileURL) }
    }

    /// Resolves genres for the given artists (cached + persisted). "" is cached
    /// for artists with no inferable genre so we don't keep re-fetching.
    func ensure(artists: [String]) {
        for name in artists where genreByArtist[name] == nil && !inFlight.contains(name) {
            inFlight.insert(name)
            Task {
                let bio = await YouTubeService.shared.artistBio(name: name) ?? ""
                genreByArtist[name] = Self.genre(from: bio) ?? ""
                inFlight.remove(name)
                persist()
            }
        }
    }

    /// Genre breakdown (label, fraction) weighted by plays, for resolved artists.
    func breakdown(weightedBy artistPlays: [(name: String, plays: Int)]) -> [(genre: String, fraction: Double)] {
        var totals: [String: Int] = [:]
        var known = 0
        for (name, plays) in artistPlays {
            guard let g = genreByArtist[name], !g.isEmpty else { continue }
            totals[g, default: 0] += plays
            known += plays
        }
        guard known > 0 else { return [] }
        return totals.sorted { $0.value > $1.value }
            .map { ($0.key, Double($0.value) / Double(known)) }
    }

    /// Distinct resolved genres across the user's listening (for the badge).
    var distinctGenreCount: Int { Set(genreByArtist.values.filter { !$0.isEmpty }).count }

    /// All genre labels (for the preferred-genres picker).
    static var allGenres: [String] { table.map(\.label).sorted() }
}
