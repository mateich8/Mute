import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import UniformTypeIdentifiers

struct Track: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var albumKey: String?
    var trackNumber: Int?
    var genre: String?
    var year: Int?
    var duration: TimeInterval
    var artworkFile: String?
    /// EBU R128 gain in dB toward -23 LUFS, computed lazily by LoudnessAnalyzer.
    var loudnessGain: Double?
    /// Optional so old library files keep decoding (nil == not favorite).
    var favorite: Bool?
    /// When the track entered the library (migrated from file creation date).
    var addedAt: Date?
    var playCount: Int?
    var lastPlayed: Date?
    /// Remote cover-art URL for streamed tracks (YouTube); nil for local files,
    /// which carry their artwork in `artworkFile`.
    var artworkURL: String?
    // Extended Get Info metadata (all optional → old library files still decode).
    var composer: String?
    var showComposer: Bool?      // "Show composer in all views"
    var grouping: String?
    var trackTotal: Int?         // the "of N" in track N of M
    var discNumber: Int?
    var discTotal: Int?
    var compilation: Bool?       // album is a compilation of various artists
    var rating: Int?             // 0…5 stars
    var bpm: Int?
    var comments: String?

    var isFavorite: Bool { favorite == true }
    var url: URL { URL(fileURLWithPath: path) }

    /// The YouTube videoId for a streamed track ("ytmusic://<id>"), else nil.
    var youtubeVideoID: String? {
        path.hasPrefix("ytmusic://") ? String(path.dropFirst(10)) : nil
    }

    /// Best cover art for the now-playing UI: the official album cover when
    /// known, otherwise the high-res YouTube video thumbnail.
    var remoteArtworkURL: URL? {
        if let artworkURL, let url = URL(string: artworkURL) { return url }
        if let id = youtubeVideoID { return URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg") }
        return nil
    }

    /// Reliable fallback (always present) if the high-res thumbnail 404s.
    var remoteArtworkFallbackURL: URL? {
        guard let id = youtubeVideoID else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

struct Playlist: Identifiable, Codable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID]
}

/// One playback event, logged for Listening History & Stats (covers everything
/// played, including streams that aren't in the library).
struct PlayEvent: Codable, Identifiable {
    var id = UUID()
    var title: String
    var artist: String
    var path: String          // "ytmusic://<id>" or a file path
    var artworkURL: String?
    var date: Date
    var videoID: String? { path.hasPrefix("ytmusic://") ? String(path.dropFirst(10)) : nil }
}

struct Album: Identifiable {
    var id: String
    var name: String
    var artist: String
    var tracks: [Track]
    var dateAdded: Date
    var playCount: Int
    var lastPlayed: Date?

    /// Remote cover for streaming albums with no local artwork (YouTube).
    var remoteArtworkURL: URL? { tracks.first(where: { $0.artworkURL != nil })?.remoteArtworkURL ?? tracks.first?.remoteArtworkURL }
    var remoteArtworkFallbackURL: URL? { tracks.first?.remoteArtworkFallbackURL }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var history: [PlayEvent] = []   // oldest → newest
    @Published private(set) var importing = false

    private let dir: URL
    private let artworkDir: URL
    private var artworkCache: [String: NSImage] = [:]

    private struct Snapshot: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var history: [PlayEvent]?
    }

    private var file: URL { dir.appendingPathComponent("library.json") }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = appSupport.appendingPathComponent("Mute")
        artworkDir = dir.appendingPathComponent("Artwork")
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tracks = snap.tracks
            playlists = snap.playlists
            history = snap.history ?? []
        }
        // Migrate entries imported before album keys existed.
        var migrated = false
        for i in tracks.indices where tracks[i].albumKey == nil {
            tracks[i] = Self.normalized(tracks[i])
            migrated = true
        }
        // Backfill added-dates from file creation dates (pre-sorting library).
        if tracks.contains(where: { $0.addedAt == nil }) {
            for i in tracks.indices where tracks[i].addedAt == nil {
                let attrs = try? FileManager.default.attributesOfItem(atPath: tracks[i].path)
                tracks[i].addedAt = (attrs?[.creationDate] as? Date) ?? .distantPast
            }
            migrated = true
        }
        if migrated { save() }
        // Pick up cover images sitting next to tracks imported before folder-art support.
        Task { self.backfillFolderArtwork() }
    }

    /// Fills in the album display name and grouping key. Untagged files take
    /// their parent folder as the album, keyed by full path so two folders
    /// with the same name stay separate albums.
    nonisolated private static func normalized(_ track: Track) -> Track {
        var t = track
        if t.album.isEmpty {
            let parent = t.url.deletingLastPathComponent()
            t.album = parent.lastPathComponent
            t.albumKey = "folder:" + parent.path.lowercased()
        } else {
            t.albumKey = "album:" + t.album.lowercased() + "|" + (t.albumArtist ?? "").lowercased()
        }
        return t
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Snapshot(tracks: tracks, playlists: playlists, history: history)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Albums (derived from track metadata)

    var albums: [Album] {
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let key = track.albumKey ?? Self.normalized(track).albumKey!
            groups[key, default: []].append(track)
        }
        return groups.map { key, grouped in
            let name = grouped[0].album.isEmpty ? "Unknown Album" : grouped[0].album
            let albumArtists = Set(grouped.compactMap { t in (t.albumArtist?.isEmpty == false) ? t.albumArtist : nil })
            let artists = Set(grouped.map(\.artist).filter { !$0.isEmpty })
            let artist = albumArtists.count == 1 ? albumArtists.first!
                : artists.count == 1 ? artists.first!
                : (artists.isEmpty ? "Unknown Artist" : "Various Artists")
            let sorted = grouped.sorted { a, b in
                // Disc number first (multi-disc albums), then track number.
                let da = a.discNumber ?? 1, db = b.discNumber ?? 1
                if da != db { return da < db }
                switch (a.trackNumber, b.trackNumber) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
                }
            }
            return Album(id: key, name: name, artist: artist, tracks: sorted,
                         dateAdded: grouped.compactMap(\.addedAt).max() ?? .distantPast,
                         playCount: grouped.reduce(0) { $0 + ($1.playCount ?? 0) },
                         lastPlayed: grouped.compactMap(\.lastPlayed).max())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Artwork

    func artwork(for track: Track?) -> NSImage? {
        guard let name = track?.artworkFile else { return nil }
        if let cached = artworkCache[name] { return cached }
        guard let data = try? Data(contentsOf: artworkDir.appendingPathComponent(name)),
              let image = NSImage(data: data) else { return nil }
        artworkCache[name] = image
        return image
    }

    func artwork(for album: Album) -> NSImage? {
        artwork(for: album.tracks.first { $0.artworkFile != nil })
    }

    // MARK: Import

    nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "aac", "adts", "flac", "alac",
        "wav", "wave", "aif", "aiff", "aifc", "caf", "mp2", "au", "snd",
        "ac3", "eac3", "amr", "opus", "oga", "ogg", "wma", "ape", "wv", "mka", "dsf",
    ]

    nonisolated static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) { return true }
        return false
    }

    nonisolated func collectAudioFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let item as URL in enumerator where Self.isAudioFile(item) {
                        files.append(item)
                    }
                }
            } else if Self.isAudioFile(url) {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Paths being imported right now — guards against concurrent importFiles
    /// calls (e.g. FSEvents fires several events per new file) racing each
    /// other across await suspension points and duplicating tracks.
    private var importsInFlight = Set<String>()

    /// Imports files/folders into the library, skipping duplicates and anything
    /// CoreAudio can't decode. Returns the newly added tracks.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Track] {
        importing = true
        defer { importing = false }

        let files = collectAudioFiles(urls)
        let known = Set(tracks.map(\.path))
        var claimed: [URL] = []
        for url in files where !known.contains(url.path) && !importsInFlight.contains(url.path) {
            importsInFlight.insert(url.path)
            claimed.append(url)
        }
        defer { for url in claimed { importsInFlight.remove(url.path) } }

        var added: [Track] = []
        for url in claimed {
            guard let track = await loadTrack(url) else { continue }
            added.append(track)
        }
        // Re-check synchronously at append time: `known` is stale after awaits.
        let current = Set(tracks.map(\.path))
        added.removeAll { current.contains($0.path) }
        if !added.isEmpty {
            tracks.append(contentsOf: added)
            save()
        }
        return added
    }

    // MARK: Streaming entries (YouTube — added without downloading)

    /// True if a YouTube videoId is already in the library (streamed or downloaded).
    func isInLibrary(youtubeID id: String) -> Bool {
        let streamPath = "ytmusic://\(id)"
        let marker = "[\(id)]"
        return tracks.contains { $0.path == streamPath || $0.path.contains(marker) }
    }

    /// Adds streaming-only tracks (path "ytmusic://<id>") to the library without
    /// downloading. They show in Songs/Albums/Artists and play by streaming.
    @discardableResult
    func addStreaming(_ newTracks: [Track]) -> [Track] {
        var known = Set(tracks.map(\.path))
        var added: [Track] = []
        for track in newTracks where !known.contains(track.path) {
            known.insert(track.path)
            var t = track
            t.addedAt = Date()
            added.append(Self.normalized(t))
        }
        if !added.isEmpty {
            tracks.append(contentsOf: added)
            save()
        }
        return added
    }

    // MARK: Play stats

    private var saveDebounce: Task<Void, Never>?

    /// Logs a play for history/stats and bumps the play count for library tracks
    /// (covers streamed tracks that aren't in the library too — they still get
    /// history). Called on every track start.
    func recordPlay(_ track: Track?) {
        guard let track else { return }
        // Don't log an immediate repeat of the same track (e.g. replay-on-seek).
        if history.last?.path != track.path || Date().timeIntervalSince(history.last?.date ?? .distantPast) > 1 {
            history.append(PlayEvent(title: track.title, artist: track.artist, path: track.path,
                                     artworkURL: track.artworkURL, date: Date()))
            if history.count > 600 { history.removeFirst(history.count - 600) }
        }
        if let i = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[i].playCount = (tracks[i].playCount ?? 0) + 1
            tracks[i].lastPlayed = Date()
        }
        // Coalesce disk writes — this fires on every track start.
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func clearHistory() { history = []; save() }

    private func loadTrack(_ url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }

        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var artworkData: Data?
        var duration: TimeInterval = 0

        if let meta = try? await asset.load(.commonMetadata) {
            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierTitle).first,
               let value = try? await item.load(.stringValue) { title = value }
            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtist).first,
               let value = try? await item.load(.stringValue) { artist = value }
            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierAlbumName).first,
               let value = try? await item.load(.stringValue) { album = value }
            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue) { artworkData = data }
        }
        if let d = try? await asset.load(.duration) { duration = d.seconds }
        if artworkData == nil { artworkData = Self.folderArtworkData(near: url) }

        let extra = await Self.extendedTags(from: asset)
        var track = Track(path: url.path, title: title, artist: artist, album: album,
                          albumArtist: extra.albumArtist, trackNumber: extra.trackNumber,
                          genre: extra.genre, year: extra.year, duration: duration,
                          addedAt: Date())
        track = Self.normalized(track)
        if let artworkData {
            track.artworkFile = storeArtwork(artworkData, album: track.album, artist: artist, trackID: track.id)
        }
        return track
    }

    private struct ExtendedTags {
        var trackNumber: Int?
        var albumArtist: String?
        var genre: String?
        var year: Int?
    }

    nonisolated private static func extendedTags(from asset: AVURLAsset) async -> ExtendedTags {
        var tags = ExtendedTags()
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return tags }
        if formats.contains(.iTunesMetadata),
           let items = try? await asset.loadMetadata(for: .iTunesMetadata) {
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataTrackNumber).first {
                if let number = try? await item.load(.numberValue) {
                    tags.trackNumber = number.intValue
                } else if let data = try? await item.load(.dataValue) {
                    let bytes = [UInt8](data)
                    if bytes.count >= 4 { tags.trackNumber = Int(bytes[2]) << 8 | Int(bytes[3]) }
                }
            }
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataAlbumArtist).first,
               let value = try? await item.load(.stringValue) { tags.albumArtist = value }
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataUserGenre).first,
               let value = try? await item.load(.stringValue) { tags.genre = value }
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataReleaseDate).first,
               let value = try? await item.load(.stringValue) { tags.year = Int(value.prefix(4)) }
        }
        if formats.contains(.id3Metadata),
           let items = try? await asset.loadMetadata(for: .id3Metadata) {
            if tags.trackNumber == nil,
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataTrackNumber).first,
               let value = try? await item.load(.stringValue) {
                tags.trackNumber = Int(value.split(separator: "/").first ?? "")
            }
            if tags.albumArtist == nil,
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataBand).first,
               let value = try? await item.load(.stringValue) { tags.albumArtist = value }
            if tags.genre == nil,
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataContentType).first,
               let value = try? await item.load(.stringValue) { tags.genre = value }
            if tags.year == nil,
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataRecordingTime).first,
               let value = try? await item.load(.stringValue) { tags.year = Int(value.prefix(4)) }
        }
        return tags
    }

    /// Applies edited tags to the library entry (file writing is handled
    /// separately by MetadataService where the container supports it).
    func updateTrackTags(id: UUID, edit: TagEdit) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        if !edit.title.trimmingCharacters(in: .whitespaces).isEmpty { tracks[i].title = edit.title }
        tracks[i].artist = edit.artist
        tracks[i].album = edit.album
        tracks[i].albumArtist = edit.albumArtist.isEmpty ? nil : edit.albumArtist
        tracks[i].genre = edit.genre.isEmpty ? nil : edit.genre
        tracks[i].year = edit.year
        tracks[i].trackNumber = edit.trackNumber
        tracks[i].trackTotal = edit.trackTotal
        tracks[i].discNumber = edit.discNumber
        tracks[i].discTotal = edit.discTotal
        tracks[i].composer = edit.composer.isEmpty ? nil : edit.composer
        tracks[i].showComposer = edit.showComposer ? true : nil
        tracks[i].grouping = edit.grouping.isEmpty ? nil : edit.grouping
        tracks[i].compilation = edit.compilation ? true : nil
        tracks[i].rating = edit.rating > 0 ? edit.rating : nil
        tracks[i].bpm = edit.bpm
        tracks[i].comments = edit.comments.isEmpty ? nil : edit.comments
        tracks[i] = Self.normalized(tracks[i])
        save()
    }

    /// Moves a track up/down within its album and re-numbers the whole album
    /// 1…N (single disc) so the order is always clean and gap-free.
    func moveTrack(inAlbum albumKey: String, id: UUID, by offset: Int) {
        guard var ordered = albums.first(where: { $0.id == albumKey })?.tracks,
              let idx = ordered.firstIndex(where: { $0.id == id }) else { return }
        let dest = idx + offset
        guard dest >= 0, dest < ordered.count else { return }
        ordered.swapAt(idx, dest)
        applyTrackNumbers(ordered)
    }

    /// Numbers an album's tracks sequentially in the given order (collapses to a
    /// single disc). Used by reorder and the album "Number Tracks" action.
    func applyTrackNumbers(_ ordered: [Track]) {
        for (i, track) in ordered.enumerated() {
            guard let j = tracks.firstIndex(where: { $0.id == track.id }) else { continue }
            tracks[j].trackNumber = i + 1
            tracks[j].trackTotal = ordered.count
            tracks[j].discNumber = nil
            tracks[j].discTotal = nil
        }
        save()
    }

    /// Sets a track's cover art from raw image data (e.g. the square YouTube
    /// Music album cover fetched at download time). Deduplicated per album.
    func setTrackArtwork(_ id: UUID, data: Data) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let name = storeArtwork(data, album: tracks[i].album,
                                artist: tracks[i].albumArtist ?? tracks[i].artist,
                                trackID: tracks[i].id, overwrite: true)
        tracks[i].artworkFile = name
        save()
    }

    /// Clears the play count / last-played for a track (Get Info → Reset).
    func resetPlayStats(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].playCount = nil
        tracks[i].lastPlayed = nil
        save()
    }

    /// Artwork is deduplicated per album so a 12-track album stores one image.
    private func storeArtwork(_ data: Data, album: String, artist: String, trackID: UUID,
                              overwrite: Bool = false) -> String {
        let name: String
        if album.isEmpty {
            name = trackID.uuidString + ".art"
        } else {
            let key = (album + "|" + artist).lowercased()
            let digest = SHA256.hash(data: Data(key.utf8))
            name = digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".art"
        }
        let target = artworkDir.appendingPathComponent(name)
        if overwrite || !FileManager.default.fileExists(atPath: target.path) {
            try? data.write(to: target)
            artworkCache.removeValue(forKey: name)
        }
        return name
    }

    // MARK: Folder artwork

    nonisolated private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "gif", "webp",
    ]

    /// Looks for a cover image in the track's folder (cover.jpg, folder.png, …).
    nonisolated private static func folderArtworkData(near url: URL) -> Data? {
        let folder = url.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let images = items.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        func rank(_ u: URL) -> Int {
            let name = u.deletingPathExtension().lastPathComponent.lowercased()
            return preferred.firstIndex { name.contains($0) } ?? preferred.count
        }
        let best = images.min { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }!
        return try? Data(contentsOf: best)
    }

    /// Called at launch and on app activation: folder scans can fail until the
    /// user grants folder/volume access, so keep retrying for art-less tracks.
    func backfillFolderArtwork() {
        var folderCache: [String: Data?] = [:]
        var changed = false
        for i in tracks.indices where tracks[i].artworkFile == nil {
            let folder = tracks[i].url.deletingLastPathComponent().path
            let data: Data?
            if let cached = folderCache[folder] {
                data = cached
            } else {
                data = Self.folderArtworkData(near: tracks[i].url)
                folderCache[folder] = data
            }
            guard let data else { continue }
            tracks[i].artworkFile = storeArtwork(data, album: tracks[i].album,
                                                 artist: tracks[i].albumArtist ?? tracks[i].artist,
                                                 trackID: tracks[i].id)
            changed = true
        }
        if changed { save() }
    }

    // MARK: Album editing

    /// Renames an album / sets its artist / replaces its cover across all of its
    /// tracks. Returns the album's new grouping key.
    @discardableResult
    func updateAlbum(key: String, name: String, artist: String, artworkData: Data?) -> String? {
        let indices = tracks.indices.filter { tracks[$0].albumKey == key }
        guard !indices.isEmpty else { return nil }

        let newName = name.trimmingCharacters(in: .whitespaces)
        let newArtist = artist.trimmingCharacters(in: .whitespaces)
        let finalName = newName.isEmpty ? tracks[indices[0]].album : newName
        let newKey = "album:" + finalName.lowercased() + "|" + newArtist.lowercased()

        var artworkFile: String?
        if let artworkData {
            artworkFile = storeArtwork(artworkData, album: finalName, artist: newArtist,
                                       trackID: tracks[indices[0]].id, overwrite: true)
        }
        for i in indices {
            tracks[i].album = finalName
            tracks[i].albumArtist = newArtist.isEmpty ? nil : newArtist
            tracks[i].albumKey = newKey
            if let artworkFile { tracks[i].artworkFile = artworkFile }
        }
        cleanupOrphanArtwork()
        save()
        return newKey
    }

    // MARK: Removal

    func removeTracks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { ids.contains($0) }
        }
        cleanupOrphanArtwork()
        save()
        Player.shared.removeFromQueue(ids: ids)
    }

    private func cleanupOrphanArtwork() {
        let referenced = Set(tracks.compactMap(\.artworkFile))
        guard let files = try? FileManager.default.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            artworkCache.removeValue(forKey: file.lastPathComponent)
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist() -> Playlist {
        var name = "New Playlist"
        var n = 2
        while playlists.contains(where: { $0.name == name }) {
            name = "New Playlist \(n)"
            n += 1
        }
        let playlist = Playlist(name: name, trackIDs: [])
        playlists.append(playlist)
        save()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        playlists[i].name = trimmed.isEmpty ? playlists[i].name : trimmed
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(trackIDs ids: [UUID], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let existing = Set(playlists[i].trackIDs)
        playlists[i].trackIDs.append(contentsOf: ids.filter { !existing.contains($0) })
        save()
    }

    func removeFromPlaylist(_ playlistID: UUID, trackID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { $0 == trackID }
        save()
    }

    func tracks(for playlist: Playlist) -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    // MARK: Favorites (Liked Music)

    var favorites: [Track] { tracks.filter(\.isFavorite) }

    func toggleFavorite(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].favorite = tracks[i].isFavorite ? nil : true
        save()
    }

    func isFavorite(path: String) -> Bool {
        tracks.contains { $0.path == path && $0.isFavorite }
    }

    /// Like/unlike any track. If it isn't in the library yet (a transient
    /// stream), add it first so "Liked Music" can hold it.
    func toggleLike(_ track: Track) {
        if let i = tracks.firstIndex(where: { $0.path == track.path }) {
            tracks[i].favorite = tracks[i].isFavorite ? nil : true
            save()
        } else {
            var t = track
            t.favorite = true
            t.addedAt = Date()
            tracks.append(Self.normalized(t))
            save()
        }
    }

    // MARK: Listening stats

    /// Library tracks with at least one play, most-played first.
    var mostPlayed: [Track] {
        tracks.filter { ($0.playCount ?? 0) > 0 }
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
    }

    /// Recently played, newest first, de-duplicated by track.
    var recentlyPlayed: [PlayEvent] {
        var seen = Set<String>(); var out: [PlayEvent] = []
        for e in history.reversed() where seen.insert(e.path).inserted {
            out.append(e)
            if out.count >= 40 { break }
        }
        return out
    }

    /// Top artists by total play count (library) blended with history counts.
    var topArtists: [(name: String, plays: Int)] {
        var counts: [String: Int] = [:]
        for t in tracks where !t.artist.isEmpty {
            counts[t.artist, default: 0] += (t.playCount ?? 0)
        }
        for e in history where !e.artist.isEmpty {
            // history may include streamed plays not in the library
            if tracks.first(where: { $0.path == e.path }) == nil {
                counts[e.artist, default: 0] += 1
            }
        }
        return counts.filter { $0.value > 0 }
            .map { (name: $0.key, plays: $0.value) }
            .sorted { $0.plays > $1.plays }
    }

    var totalPlays: Int { history.count }

    // MARK: Loudness

    func setLoudnessGain(_ gain: Double, for id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].loudnessGain = gain
        save()
    }

    /// Average gain across an album, for album-mode normalization.
    func albumGain(for track: Track) -> Double? {
        let key = track.albumKey
        let gains = tracks.filter { $0.albumKey == key }.compactMap(\.loudnessGain)
        guard !gains.isEmpty else { return track.loudnessGain }
        return gains.reduce(0, +) / Double(gains.count)
    }

    // MARK: Dominant color (chromatic UI)

    private var colorCache: [String: NSColor] = [:]

    func dominantColor(for track: Track?) -> NSColor? {
        guard let name = track?.artworkFile else { return nil }
        if let cached = colorCache[name] { return cached }
        guard let image = artwork(for: track),
              let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage",
                              parameters: [kCIInputImageKey: ci,
                                           kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        colorCache[name] = color
        return color
    }
}
