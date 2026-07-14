import SwiftUI
import AppKit

enum GlassStyle: String, CaseIterable, Identifiable {
    case glassy, regular
    var id: String { rawValue }

    var label: String {
        switch self {
        case .glassy: return "Glassy"
        case .regular: return "Regular"
        }
    }
}

/// Gain curves for the 10 bands (32 Hz … 16 kHz), in dB.
struct EQPreset: Identifiable {
    let name: String
    let gains: [Double]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Rock", gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        EQPreset(name: "Pop", gains: [-1, 1, 3, 4, 3, 1, -1, -1, 1, 2]),
        EQPreset(name: "Hip-Hop", gains: [6, 5, 3, 1, -1, -1, 1, 2, 3, 4]),
        EQPreset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 1, 2, 4, 5]),
        EQPreset(name: "Jazz", gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        EQPreset(name: "Classical", gains: [3, 2, 1, 0, 0, 0, -1, 1, 2, 3]),
        EQPreset(name: "Acoustic", gains: [4, 3, 2, 1, 1, 1, 2, 3, 3, 2]),
        EQPreset(name: "Bass Boost", gains: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Vocal", gains: [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]),
    ]
}

enum AlbumSort: String, CaseIterable, Identifiable {
    case name, artist, relevance, dateAdded, mostPlayed
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .artist: return "Artist"
        case .relevance: return "Relevance"
        case .dateAdded: return "Date Added"
        case .mostPlayed: return "Most Played"
        }
    }
}

enum NormalizationMode: String, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        }
    }
}

enum BackdropMode: String, CaseIterable, Identifiable {
    case color, glass, albumArt
    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return "Color"
        case .glass: return "Glass"
        case .albumArt: return "Album Art"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var glassStyle: GlassStyle {
        didSet { defaults.set(glassStyle.rawValue, forKey: "glassStyle") }
    }
    /// 0 = pure glass, 1 = heavily frosted.
    @Published var frost: Double {
        didSet { defaults.set(frost, forKey: "frost") }
    }
    @Published var backdropMode: BackdropMode {
        didSet { defaults.set(backdropMode.rawValue, forKey: "backdropMode") }
    }
    @Published var backgroundColor: Color {
        didSet { persistColor() }
    }
    /// Seconds of crossfade between tracks; 0 = gapless (sample-accurate butt joint).
    @Published var crossfade: Double {
        didSet { defaults.set(crossfade, forKey: "crossfade") }
    }
    @Published var normalizationMode: NormalizationMode {
        didSet {
            defaults.set(normalizationMode.rawValue, forKey: "normalization")
            Player.shared.refreshLoudness()
            if normalizationMode != .off { LoudnessScanner.shared.kick() }
        }
    }
    @Published var bitPerfect: Bool {
        didSet {
            defaults.set(bitPerfect, forKey: "bitPerfect")
            Player.shared.refreshAudioPath()
        }
    }
    @Published var albumSort: AlbumSort {
        didSet { defaults.set(albumSort.rawValue, forKey: "albumSort") }
    }
    /// Show synced lyrics on the Now Playing screen (YouTube tracks).
    @Published var showLyrics: Bool {
        didSet { defaults.set(showLyrics, forKey: "showLyrics") }
    }
    /// Genius API token (free, from genius.com/api-clients) for song trivia.
    @Published var geniusToken: String {
        didSet { defaults.set(geniusToken, forKey: "geniusToken") }
    }
    // Qobuz (hi-res search + downloads via the user's own subscription).
    @Published var qobuzEnabled: Bool {
        didSet { defaults.set(qobuzEnabled, forKey: "qobuzEnabled") }
    }
    @Published var qobuzEmail: String {
        didSet { defaults.set(qobuzEmail, forKey: "qobuzEmail") }
    }
    @Published var qobuzPassword: String {
        didSet { defaults.set(qobuzPassword, forKey: "qobuzPassword") }
    }
    /// Download quality: 5 = MP3 320, 6 = CD FLAC, 7 = FLAC ≤96 kHz, 27 = FLAC >96 kHz.
    @Published var qobuzQuality: Int {
        didSet { defaults.set(qobuzQuality, forKey: "qobuzQuality") }
    }
    @Published var eqEnabled: Bool {
        didSet {
            defaults.set(eqEnabled, forKey: "eqEnabled")
            Player.shared.applyEQ()
        }
    }
    /// Ten band gains in dB (-12…+12), low to high frequency.
    @Published var eqGains: [Double] {
        didSet {
            defaults.set(eqGains, forKey: "eqGains")
            Player.shared.applyEQ()
        }
    }

    static let defaultBackground = Color(.sRGB, red: 0.10, green: 0.10, blue: 0.14, opacity: 1)

    init() {
        glassStyle = GlassStyle(rawValue: defaults.string(forKey: "glassStyle") ?? "") ?? .regular
        frost = defaults.object(forKey: "frost") as? Double ?? 0
        backdropMode = BackdropMode(rawValue: defaults.string(forKey: "backdropMode") ?? "") ?? .color
        if let c = defaults.array(forKey: "bgColor") as? [Double], c.count == 3 {
            backgroundColor = Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
        } else {
            backgroundColor = Self.defaultBackground
        }
        crossfade = defaults.object(forKey: "crossfade") as? Double ?? 0
        normalizationMode = NormalizationMode(rawValue: defaults.string(forKey: "normalization") ?? "") ?? .off
        bitPerfect = defaults.bool(forKey: "bitPerfect")
        albumSort = AlbumSort(rawValue: defaults.string(forKey: "albumSort") ?? "") ?? .name
        showLyrics = defaults.object(forKey: "showLyrics") as? Bool ?? true
        geniusToken = defaults.string(forKey: "geniusToken") ?? ""
        qobuzEnabled = defaults.object(forKey: "qobuzEnabled") as? Bool ?? true
        qobuzEmail = defaults.string(forKey: "qobuzEmail") ?? ""
        qobuzPassword = defaults.string(forKey: "qobuzPassword") ?? ""
        qobuzQuality = defaults.object(forKey: "qobuzQuality") as? Int ?? 6
        eqEnabled = defaults.bool(forKey: "eqEnabled")
        if let gains = defaults.array(forKey: "eqGains") as? [Double], gains.count == 10 {
            eqGains = gains
        } else {
            eqGains = Array(repeating: 0, count: 10)
        }
    }

    private func persistColor() {
        guard let ns = NSColor(backgroundColor).usingColorSpace(.sRGB) else { return }
        defaults.set([ns.redComponent, ns.greenComponent, ns.blueComponent].map(Double.init), forKey: "bgColor")
    }

    var glass: Glass {
        glassStyle == .glassy ? .clear : .regular
    }

    var frostOpacity: Double { frost * 0.32 }

    /// In glass mode the window itself goes translucent and frosts the desktop
    /// behind it; otherwise the in-window Backdrop paints over an opaque base.
    /// Regular (not ultra-thin) material: thin material lets bright desktop
    /// features bleed through as blotches/bands behind the dark UI.
    var windowBackground: AnyShapeStyle {
        backdropMode == .glass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black)
    }

    func reset() {
        glassStyle = .regular
        frost = 0
        backdropMode = .color
        backgroundColor = Self.defaultBackground
        crossfade = 0
        eqEnabled = false
        eqGains = Array(repeating: 0, count: 10)
    }
}

extension View {
    /// App-wide glass surface honoring the user's glass/frost settings.
    /// Callers must observe `Settings.shared` so changes re-render them.
    func appGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        let settings = Settings.shared
        return self
            .background(shape.fill(.white.opacity(settings.frostOpacity)))
            .glassEffect(interactive ? settings.glass.interactive() : settings.glass, in: shape)
    }
}
