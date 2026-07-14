import SwiftUI
import Foundation

// MARK: - Qobuz models

struct QBAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let year: String
    let trackCount: Int
    let cover: URL?
    let hires: Bool
}

struct QBTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let cover: URL?
    let hires: Bool
}

// MARK: - Qobuz service (structure = qobuz-dl in the shared venv, like ytmusicapi)

/// Search and download hi-res music from Qobuz via the user's own Qobuz
/// subscription (qobuz-dl). Downloads come fully tagged with embedded art, so
/// they import into the library as proper albums with no re-tagging.
@MainActor
final class QobuzService: ObservableObject {
    static let shared = QobuzService()
    private let defaults = UserDefaults.standard

    // Setup state
    @Published private(set) var moduleReady = false     // qobuz_dl importable in the venv
    @Published private(set) var installing = false
    @Published private(set) var checking = false
    /// Result of the last credentials check: nil = never checked, "" = ok.
    @Published private(set) var accountError: String?
    @Published private(set) var accountLabel: String?   // e.g. "Studio" plan

    // Search state
    @Published var query = ""
    @Published private(set) var searching = false
    @Published private(set) var albums: [QBAlbum] = []
    @Published private(set) var tracks: [QBTrack] = []
    @Published private(set) var searchError: String?

    /// Download state keyed by "t<id>" / "a<id>" (same enum as YouTube).
    @Published private(set) var downloads: [String: DownloadState] = [:]

    var configured: Bool { !Settings.shared.qobuzEmail.isEmpty && !Settings.shared.qobuzPassword.isEmpty }
    var ready: Bool { moduleReady && configured }

    private init() {
        Self.ensureHelper()
        refreshModule()
    }

    // MARK: Setup

    nonisolated static var helperPath: String { YouTubeService.appSupportDir.appendingPathComponent("qobuz_helper.py").path }

    nonisolated static func ensureHelper() {
        try? helperSource.data(using: .utf8)?.write(to: URL(fileURLWithPath: helperPath))
    }

    /// Downloads land here, then import into the library.
    nonisolated static let downloadDir: URL = {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let dir = base.appendingPathComponent("Mute/Qobuz")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func refreshModule() {
        Task.detached(priority: .utility) {
            let ok: Bool = {
                guard let py = YouTubeService.venvPython() else { return false }
                return YouTubeService.runSync(py, ["-c", "import qobuz_dl"]).code == 0
            }()
            await MainActor.run { self.moduleReady = ok }
        }
    }

    /// Installs qobuz-dl into the shared venv (the venv itself comes from the
    /// YouTube Music setup, which is the app's baseline install).
    func installModule() {
        guard let py = YouTubeService.venvPython(), !installing else { return }
        installing = true
        Task.detached(priority: .utility) {
            _ = YouTubeService.runSync(py, ["-m", "pip", "install", "--quiet", "qobuz-dl"])
            await MainActor.run {
                self.installing = false
                self.refreshModule()
            }
        }
    }

    /// Verifies the credentials by logging in once; reports the plan label.
    func checkAccount() {
        guard ready, !checking else { return }
        checking = true
        accountError = nil
        accountLabel = nil
        let creds = Credentials.current()
        Task {
            let (data, err) = await Task.detached { Self.runHelper(["check"], creds) }.value
            checking = false
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                accountError = err ?? "Couldn’t reach Qobuz."
                return
            }
            if let e = obj["error"] as? String {
                accountError = e
            } else {
                accountError = ""
                accountLabel = obj["label"] as? String
            }
        }
    }

    // MARK: Search

    private var searchTask: Task<Void, Never>?

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !q.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        searchError = nil
        let creds = Credentials.current()
        searchTask = Task {
            let (data, err) = await Task.detached { Self.runHelper(["search", q], creds) }.value
            guard !Task.isCancelled else { return }
            searching = false
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                searchError = err ?? "Search failed."
                return
            }
            if let e = obj["error"] as? String { searchError = e; return }
            albums = Self.parseAlbums(obj["albums"])
            tracks = Self.parseTracks(obj["tracks"])
            if albums.isEmpty && tracks.isEmpty { searchError = "No results." }
        }
    }

    nonisolated private static func parseAlbums(_ raw: Any?) -> [QBAlbum] {
        (raw as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String, let title = a["title"] as? String else { return nil }
            return QBAlbum(id: id, title: title,
                           artist: a["artist"] as? String ?? "",
                           year: a["year"] as? String ?? "",
                           trackCount: a["tracks"] as? Int ?? 0,
                           cover: (a["cover"] as? String).flatMap(URL.init(string:)),
                           hires: a["hires"] as? Bool ?? false)
        }
    }

    nonisolated private static func parseTracks(_ raw: Any?) -> [QBTrack] {
        (raw as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"], let title = t["title"] as? String else { return nil }
            return QBTrack(id: "\(id)", title: title,
                           artist: t["artist"] as? String ?? "",
                           album: t["album"] as? String ?? "",
                           duration: t["duration"] as? Double ?? 0,
                           cover: (t["cover"] as? String).flatMap(URL.init(string:)),
                           hires: t["hires"] as? Bool ?? false)
        }
    }

    // MARK: Download

    func download(track: QBTrack) { download(kind: "track", id: track.id, key: "t\(track.id)") }
    func download(album: QBAlbum) { download(kind: "album", id: album.id, key: "a\(album.id)") }

    func state(forTrack id: String) -> DownloadState? { downloads["t\(id)"] }
    func state(forAlbum id: String) -> DownloadState? { downloads["a\(id)"] }

    private func download(kind: String, id: String, key: String) {
        guard ready else { return }
        if case .downloading = downloads[key] { return }
        downloads[key] = .downloading(-1)
        let creds = Credentials.current()
        Task {
            let (data, err) = await Task.detached { Self.runHelper(["download", kind, id], creds) }.value
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["error"] == nil else {
                let message = ((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any])?["error"] as? String
                downloads[key] = .failed(message ?? err ?? "Download failed.")
                return
            }
            // qobuz-dl wrote fully tagged files (with embedded art) — import them.
            let files = (obj["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            if !files.isEmpty {
                await Library.shared.importFiles(files)
            }
            downloads[key] = .done
        }
    }

    // MARK: Helper bridge

    /// Snapshot of the credentials/config, captured on the main actor before
    /// hopping to a background task.
    struct Credentials: Sendable {
        let email: String, password: String, quality: Int
        @MainActor static func current() -> Credentials {
            Credentials(email: Settings.shared.qobuzEmail,
                        password: Settings.shared.qobuzPassword,
                        quality: Settings.shared.qobuzQuality)
        }
    }

    /// Runs the Python helper with credentials/config passed via the
    /// environment (never argv, so they don't show up in the process list).
    nonisolated private static func runHelper(_ args: [String], _ creds: Credentials) -> (Data?, String?) {
        guard let py = YouTubeService.venvPython() else { return (nil, "Music tools not installed.") }
        ensureHelper()
        let (email, password, quality) = (creds.email, creds.password, creds.quality)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [helperPath] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:" + (env["PATH"] ?? "")
        env["QB_EMAIL"] = email
        env["QB_PASSWORD"] = password
        env["QB_QUALITY"] = String(quality)
        env["QB_DIR"] = downloadDir.path
        env["QB_CACHE"] = YouTubeService.appSupportDir.appendingPathComponent("qobuz_tokens.json").path
        proc.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "mute.qobuz.read", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try proc.run() } catch { return (nil, error.localizedDescription) }
        proc.waitUntilExit()
        group.wait()
        guard proc.terminationStatus == 0, !outData.isEmpty else {
            let err = String(decoding: errData, as: UTF8.self)
            let line = err.split(separator: "\n").last.map(String.init)
            return (nil, line ?? "Qobuz helper failed.")
        }
        return (outData, nil)
    }

    // MARK: Python helper

    // qobuz-dl logs chatter to stdout, so the helper swaps stdout→stderr while
    // working and restores it only to print the final JSON line.
    nonisolated private static let helperSource = #"""
    import json
    import os
    import sys
    import warnings

    warnings.filterwarnings("ignore")

    def main():
        real_stdout = sys.stdout
        sys.stdout = sys.stderr        # keep library chatter out of the JSON

        def emit(obj):
            sys.stdout = real_stdout
            print(json.dumps(obj))
            sys.exit(0)

        from qobuz_dl.core import QobuzDL

        email = os.environ.get("QB_EMAIL", "")
        password = os.environ.get("QB_PASSWORD", "")
        quality = int(os.environ.get("QB_QUALITY", "6"))
        directory = os.environ.get("QB_DIR", os.path.expanduser("~/Music/Mute/Qobuz"))
        cache_path = os.environ.get("QB_CACHE", "")
        if not email or not password:
            emit({"error": "Add your Qobuz account in Settings."})

        q = QobuzDL(directory=directory, quality=quality, embed_art=True)

        # get_tokens() scrapes the Qobuz web bundle (slow); cache app_id/secrets.
        tokens = None
        if cache_path and os.path.exists(cache_path):
            try:
                with open(cache_path) as f:
                    tokens = json.load(f)
            except Exception:
                tokens = None
        if tokens:
            q.app_id, q.secrets = tokens["app_id"], tokens["secrets"]
        else:
            q.get_tokens()
            if cache_path:
                try:
                    with open(cache_path, "w") as f:
                        json.dump({"app_id": q.app_id, "secrets": q.secrets}, f)
                except Exception:
                    pass

        def login():
            try:
                q.initialize_client(email, password, q.app_id, q.secrets)
            except Exception as e:
                msg = str(e) or type(e).__name__
                if "credentials" in msg.lower() or "401" in msg:
                    msg = "Wrong email or password."
                # A stale cached app_id can also fail auth — retry once fresh.
                if cache_path and os.path.exists(cache_path):
                    try:
                        os.remove(cache_path)
                        q.get_tokens()
                        q.initialize_client(email, password, q.app_id, q.secrets)
                        return
                    except Exception:
                        pass
                emit({"error": msg})

        def thumb(image):
            if not isinstance(image, dict):
                return ""
            return image.get("large") or image.get("small") or image.get("thumbnail") or ""

        cmd = sys.argv[1]
        if cmd == "check":
            login()
            label = ""
            try:
                cred = q.client.api_call("user/login", email=email, pwd=password)
                label = ((cred.get("user") or {}).get("credential") or {}).get("description") or ""
            except Exception:
                pass
            emit({"ok": True, "label": label})

        elif cmd == "search":
            login()
            query = sys.argv[2]
            out = {"albums": [], "tracks": []}
            try:
                res = q.client.search_albums(query, 12)
                for a in ((res.get("albums") or {}).get("items") or []):
                    if not a.get("streamable", True):
                        continue
                    out["albums"].append({
                        "id": str(a.get("id") or ""),
                        "title": a.get("title") or "",
                        "artist": ((a.get("artist") or {}).get("name")) or "",
                        "year": (a.get("release_date_original") or "")[:4],
                        "tracks": a.get("tracks_count") or 0,
                        "cover": thumb(a.get("image")),
                        "hires": bool(a.get("hires") or (a.get("maximum_bit_depth") or 16) > 16),
                    })
            except Exception:
                pass
            try:
                res = q.client.search_tracks(query, 20)
                for t in ((res.get("tracks") or {}).get("items") or []):
                    if not t.get("streamable", True):
                        continue
                    album = t.get("album") or {}
                    out["tracks"].append({
                        "id": t.get("id"),
                        "title": t.get("title") or "",
                        "artist": ((t.get("performer") or {}).get("name"))
                                  or ((album.get("artist") or {}).get("name")) or "",
                        "album": album.get("title") or "",
                        "duration": t.get("duration") or 0,
                        "cover": thumb(album.get("image")),
                        "hires": bool(t.get("hires") or (t.get("maximum_bit_depth") or 16) > 16),
                    })
            except Exception:
                pass
            emit(out)

        elif cmd == "download":
            login()
            kind, item_id = sys.argv[2], sys.argv[3]
            def audio_files():
                found = set()
                for root, _, names in os.walk(directory):
                    for n in names:
                        if n.lower().endswith((".flac", ".mp3", ".m4a", ".wav")):
                            found.add(os.path.join(root, n))
                return found
            before = audio_files()
            try:
                q.download_from_id(item_id, album=(kind == "album"))
            except Exception as e:
                emit({"error": str(e) or type(e).__name__})
            new = sorted(audio_files() - before)
            emit({"files": new})

        else:
            emit({"error": "unknown command"})

    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        # stdout may still be swapped to stderr — use the real one.
        print(json.dumps({"error": str(e) or type(e).__name__}), file=sys.__stdout__)
    """#
}
