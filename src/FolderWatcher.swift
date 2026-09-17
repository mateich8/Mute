import Foundation
import CoreServices

/// Watches user-selected folders with FSEvents and imports new audio files
/// into the library automatically (e.g. a DAW bounces folder).
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    @Published private(set) var folders: [String]
    private var stream: FSEventStreamRef?

    /// The app's own download folder is always watched and swept, even though
    /// it never appears in `folders` and can't be removed. Downloads otherwise
    /// only ever reach the library through the one-shot import that runs when a
    /// download finishes — so a lost or reset library.json used to orphan every
    /// downloaded file permanently, with nothing left that could rediscover it.
    private var implicitFolders: [String] { [YouTubeService.downloadDir.path] }

    /// Everything the stream watches and a sweep imports: the user's folders
    /// plus the implicit ones, de-duplicated in case they overlap.
    var watchPaths: [String] { folders + implicitFolders.filter { !folders.contains($0) } }

    init() {
        folders = UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? []
    }

    /// Call at launch: starts the stream and sweeps once to pick up files
    /// added while the app wasn't running.
    func start() {
        restart()
        sweep()
    }

    /// Re-imports every watched path. Cheap to repeat — `importFiles` skips
    /// paths already in the library — so this doubles as the manual "Rescan"
    /// action in Settings ▸ Library.
    func sweep() {
        let paths = watchPaths
        guard !paths.isEmpty else { return }
        Task { await Library.shared.importFiles(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func add(_ url: URL) {
        let path = url.path
        guard !folders.contains(path) else { return }
        folders.append(path)
        persist()
        restart()
        Task { await Library.shared.importFiles([url]) }
    }

    func remove(_ path: String) {
        folders.removeAll { $0 == path }
        persist()
        restart()
    }

    private func persist() {
        UserDefaults.standard.set(folders, forKey: "watchedFolders")
    }

    private func restart() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let watched = watchPaths
        guard !watched.isEmpty else { return }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagIgnoreSelf)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: CFArray.self) as NSArray) as? [String] ?? []
            Task { @MainActor in watcher.handleEvents(paths) }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context,
                                                watched as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
        stream = created
    }

    private func handleEvents(_ paths: [String]) {
        // FileEvents granularity: paths are individual files; importFiles
        // deduplicates, so re-reported known files are no-ops.
        let candidates = paths.map { URL(fileURLWithPath: $0) }.filter { Library.isAudioFile($0) }
        guard !candidates.isEmpty else { return }
        Task { await Library.shared.importFiles(candidates) }
    }
}
