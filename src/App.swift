import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A generous shared cache so album/artist covers (AsyncImage) persist in
        // memory + on disk — navigating back to a grid is instant, and covers
        // survive relaunches instead of re-downloading.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20,   // 64 MB
                                   diskCapacity: 512 << 20,     // 512 MB
                                   diskPath: "mute-img-cache")
        // Don't let macOS restore a stale saved window on top of the fresh scene
        // window — that double-layering made the title bar / panels look broken.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Move the legacy "GlassPlay" data directories into place before any
        // singleton touches the filesystem. Idempotent: once renamed the old
        // directory is gone, so this becomes a no-op.
        Self.migrateLegacyData()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    /// Makes the main window non-restorable and full-bleed with a transparent
    /// titlebar, so the standard macOS traffic lights stay anchored to the native
    /// window frame's top-left (over the backdrop), while our content fills the
    /// window. The floating cards reserve a titlebar strip (kTitlebarStrip) below
    /// the lights, so the buttons never overlap the sidebar's rounded card.
    static func configureMainWindow(attempt: Int = 0) {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else {
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { configureMainWindow(attempt: attempt + 1) }
                }
                return
            }
            w.isRestorable = false
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
        }
    }

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

    /// One-time rename of the legacy "GlassPlay" data directories to "Mute".
    /// Runs before any singleton initializes so Library/YouTube read the moved
    /// paths. Idempotent: a no-op once the old directory is gone.
    static func migrateLegacyData() {
        let fm = FileManager.default
        let pairs: [(URL, URL)] = [
            (fm.appSupport(named: "GlassPlay"),  fm.appSupport(named: "Mute")),
            (fm.music(named: "GlassPlay"),        fm.music(named: "Mute")),
        ]
        for (old, new) in pairs where fm.fileExists(atPath: old.path) {
            if fm.fileExists(atPath: new.path) {
                // Destination already exists (e.g. an empty dir a singleton made
                // before this ran) — merge in anything it's missing.
                mergeMove(old, into: new)
            } else {
                try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: old, to: new)
            }
        }
    }

    /// Moves each item from `from` into `to` that `to` lacks, recursing into
    /// directories present in both (so an empty pre-created destination still
    /// receives the real data). Never overwrites existing files.
    private static func mergeMove(_ from: URL, into to: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            var destIsDir: ObjCBool = false
            if !fm.fileExists(atPath: dest.path, isDirectory: &destIsDir) {
                try? fm.moveItem(at: item, to: dest)
            } else if destIsDir.boolValue,
                      (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                mergeMove(item, into: dest)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Library.shared.backfillFolderArtwork() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // mute:// automation URLs (Shortcuts "Open URL", AppleScript, CLI).
        for url in urls where url.scheme == "mute" {
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

    /// mute://play | pause | toggle | next | previous
    /// mute://playlist?name=Focus — mute://album?name=Koloss
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

private extension FileManager {
    func appSupport(named: String) -> URL {
        urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(named)
    }
    func music(named: String) -> URL {
        (urls(for: .musicDirectory, in: .userDomainMask).first
            ?? homeDirectoryForCurrentUser.appendingPathComponent("Music"))
            .appendingPathComponent(named)
    }
}

@main
struct MuteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Mute", id: "main") {
            ContentView()
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    AppDelegate.configureMainWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 720)
    }
}
