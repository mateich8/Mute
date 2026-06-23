import Foundation
import CoreServices

/// Watches user-selected folders with FSEvents and imports new audio files
/// into the library automatically (e.g. a DAW bounces folder).
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    @Published private(set) var folders: [String]
    private var stream: FSEventStreamRef?

    init() {
        folders = UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? []
    }

    /// Call at launch: starts the stream and sweeps folders once to pick up
    /// files added while the app wasn't running.
    func start() {
        restart()
        let existing = folders
        if !existing.isEmpty {
            Task { await Library.shared.importFiles(existing.map { URL(fileURLWithPath: $0) }) }
        }
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
        guard !folders.isEmpty else { return }

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
                                                folders as CFArray,
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
