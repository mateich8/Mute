import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NowPlayingBridge.shared.setup()
        FolderWatcher.shared.start()
        KeyboardShortcuts.install()
        LoudnessScanner.shared.kick()
        Self.updateDockIcon()
        // Legacy .icns can't auto-switch with appearance (needs Xcode's compiled
        // icon stack), so swap the Dock tile ourselves when the theme changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
            Task { @MainActor in Self.updateDockIcon() }
        }
    }

    @MainActor
    static func updateDockIcon() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        // Bundle default (AppIcon) is the dark design; light swaps in at runtime.
        let name = dark ? "AppIcon" : "AppIcon-Light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        // The system squircle-masks bundle icons but NOT runtime-set Dock icons,
        // so bake the standard mask (824pt content, 185pt radius) in ourselves.
        let masked = NSImage(size: NSSize(width: 1024, height: 1024))
        masked.lockFocus()
        let content = NSRect(x: 100, y: 100, width: 824, height: 824)
        NSBezierPath(roundedRect: content, xRadius: 185, yRadius: 185).addClip()
        image.draw(in: content)
        masked.unlockFocus()
        NSApp.applicationIconImage = masked
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Library.shared.backfillFolderArtwork() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // glassplay:// automation URLs (Shortcuts "Open URL", AppleScript, CLI).
        for url in urls where url.scheme == "glassplay" {
            Self.handleCommand(url)
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        Task { @MainActor in
            await Library.shared.importFiles(files)
            // Play whatever was opened, whether it was just imported or already in the library.
            let opened = Set(Library.shared.collectAudioFiles(files).map(\.path))
            let queue = Library.shared.tracks.filter { opened.contains($0.path) }
            if !queue.isEmpty {
                Player.shared.play(queue: queue, at: 0)
                UIState.shared.tab = .nowPlaying
            }
        }
    }

    /// glassplay://play | pause | toggle | next | previous
    /// glassplay://playlist?name=Focus — glassplay://album?name=Koloss
    @MainActor
    private static func handleCommand(_ url: URL) {
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "name" }?.value ?? ""
        switch url.host?.lowercased() {
        case "play":
            if !Player.shared.isPlaying { Player.shared.togglePlay() }
        case "pause":
            if Player.shared.isPlaying { Player.shared.togglePlay() }
        case "toggle":
            Player.shared.togglePlay()
        case "next":
            Player.shared.next()
        case "previous":
            Player.shared.previous()
        case "playlist":
            if let playlist = Library.shared.playlists.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                let tracks = Library.shared.tracks(for: playlist)
                if !tracks.isEmpty {
                    Player.shared.play(queue: tracks, at: 0)
                    UIState.shared.tab = .nowPlaying
                }
            }
        case "album":
            if let album = Library.shared.albums.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                Player.shared.play(queue: album.tracks, at: 0)
                UIState.shared.tab = .nowPlaying
            }
        default:
            break
        }
    }
}

@main
struct GlassPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Glass Play", id: "main") {
            ContentView()
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 700)
    }
}
