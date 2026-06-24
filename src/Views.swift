import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Tab: String, CaseIterable, Identifiable {
    case nowPlaying, songs, albums, artists, playlists, youtube
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .nowPlaying: return "waveform"
        case .songs: return "music.note"
        case .albums: return "square.grid.2x2"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
        case .youtube: return "play.rectangle.fill"
        }
    }

    var help: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .youtube: return "YouTube"
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var tab: Tab = .albums {
        didSet { if tab != .nowPlaying { lastLibraryTab = tab } }
    }
    @Published var showQueue = false
    /// Track for which the Get Info sheet is open.
    @Published var infoTrack: Track?
    /// Where the Now Playing back button returns to.
    private(set) var lastLibraryTab: Tab = .albums
    // Smart search
    @Published var searchVisible = false
    @Published var searchText = ""
    @Published var debouncedSearch = ""
    @Published var searchScope: SearchScope = .all
    /// Bumped to ask the search field to grab focus.
    @Published var searchFocusToken = 0
    // Zen mode + gesture-driven artwork zoom
    @Published var zenMode = false
    @Published var artZoom: CGFloat = 1.0
    // Selections live here (not view @State) so they survive tab switches.
    @Published var albumSelection: String?
    @Published var artistSelection: String?
    @Published var playlistSelection: UUID?
    /// Finder-style multi-selection of album keys (⌘-click / ⇧-click).
    @Published var albumMultiSelection: Set<String> = []
    /// Anchor for ⇧-click range selection.
    var albumSelectionAnchor: String?
    /// Albums grid: show only the newest additions.
    @Published var recentlyAddedOnly = false
}

enum SearchScope: String, CaseIterable, Identifiable {
    case all, songs, albums
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .songs: return "Songs"
        case .albums: return "Albums"
        }
    }
}

// MARK: - Root

/// Sidebar width, used to keep the floating mini-player centered over content.
let kSidebarWidth: CGFloat = 236
/// Inset from the window edge and panel corner radius. Chosen so the panel
/// corners nest concentrically inside the window's own rounded corner
/// (panelRadius ≈ windowRadius − inset on macOS Tahoe).
let kPanelInset: CGFloat = 8
let kPanelRadius: CGFloat = 16

struct ContentView: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var settings = Settings.shared
    @State private var showImporter = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Backdrop()

            HStack(spacing: 0) {
                Sidebar(showSettings: $showSettings, showImporter: $showImporter)
                MainArea(showImporter: $showImporter)
            }
            // Begin the panels just below the traffic lights (which float over the
            // backdrop), so the window buttons have clean room.
            .padding(.top, 26)
            .ignoresSafeArea(.container, edges: .top)

            if ui.showQueue { queuePanel }
            if ui.zenMode { ZenModeView().zIndex(10).transition(.opacity) }
        }
        .overlay(alignment: .trailing) { QueueDragZones() }
        .overlay(alignment: .bottom) {
            if ui.tab != .nowPlaying, player.current != nil {
                MiniBar()
                    .padding(.bottom, 22)
                    .padding(.leading, kSidebarWidth + kPanelInset + 4)
                    .padding(.trailing, kPanelInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .containerBackground(settings.windowBackground, for: .window)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(item: $ui.infoTrack) { track in TrackInfoSheet(track: track) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        // .dropDestination(for: URL.self) prevents the window from opening on macOS 26 — use onDrop
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            cont.resume(returning: url)
                        }
                    }
                    if let url { urls.append(url) }
                }
                await library.importFiles(urls)
            }
            return true
        }
    }

    private var queuePanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Queue")
                        .font(.headline)
                    Spacer()
                    Button { withAnimation(.smooth(duration: 0.35)) { ui.showQueue = false } } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close queue")
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(player.tracks.enumerated()), id: \.element.id) { index, track in
                            QueueRow(track: track,
                                     isCurrent: index == player.currentIndex,
                                     isPlaying: player.isPlaying,
                                     play: { player.play(at: index) },
                                     remove: { player.removeFromQueue(ids: [track.id]) })
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 270)
            .frame(maxHeight: .infinity)
            .appGlass(in: .rect(cornerRadius: 26))
            .padding(.vertical, 70)
            .padding(.trailing, 20)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var showSettings: Bool
    @Binding var showImporter: Bool
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var youtube = YouTubeService.shared

    private var librarySections: [Tab] {
        [.nowPlaying, .songs, .albums, .artists, .playlists]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                Text("MUTE")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Library")
                    ForEach(librarySections) { navRow($0) }

                    if !library.playlists.isEmpty {
                        sectionHeader("Playlists").padding(.top, 16)
                        ForEach(library.playlists) { playlistRow($0) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            Divider().opacity(0.2).padding(.horizontal, 16)
            HStack(spacing: 8) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .help("Settings")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: kSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: kPanelRadius))
        .appGlass(in: .rect(cornerRadius: kPanelRadius))
        .padding(.leading, kPanelInset)
        .padding(.vertical, kPanelInset)
        .padding(.trailing, kPanelInset / 2)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func navRow(_ tab: Tab) -> some View {
        let selected = ui.tab == tab && ui.debouncedSearch.isEmpty
        return Button {
            withAnimation(.smooth(duration: 0.25)) {
                ui.tab = tab
                if tab != .artists { ui.artistSelection = nil }
                clearSearch()
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.icon).font(.system(size: 13)).frame(width: 18)
                Text(tab.help).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(.white.opacity(0.13)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
    }

    private func playlistRow(_ pl: Playlist) -> some View {
        let selected = ui.tab == .playlists && ui.playlistSelection == pl.id && ui.debouncedSearch.isEmpty
        return Button {
            withAnimation(.smooth(duration: 0.25)) {
                ui.tab = .playlists
                ui.playlistSelection = pl.id
                clearSearch()
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "music.note.list").font(.system(size: 12)).frame(width: 18)
                    .foregroundStyle(.tertiary)
                Text(pl.name).font(.callout).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.white.opacity(0.13)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
    }

    private func clearSearch() {
        ui.searchText = ""; ui.debouncedSearch = ""; ui.searchVisible = false
    }
}

// MARK: - Main content area

struct MainArea: View {
    @Binding var showImporter: Bool
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var library = Library.shared

    private var sectionTitle: String {
        if !ui.debouncedSearch.isEmpty { return "Search" }
        switch ui.tab {
        case .nowPlaying: return "Now Playing"
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .youtube: return "YouTube"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            if !ui.debouncedSearch.isEmpty {
                SearchResultsView()
            } else {
                content
                    .id(ui.tab)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: kPanelRadius))
        .clipShape(RoundedRectangle(cornerRadius: kPanelRadius))
        .appGlass(in: .rect(cornerRadius: kPanelRadius))
        .padding(.trailing, kPanelInset)
        .padding(.vertical, kPanelInset)
        .padding(.leading, kPanelInset / 2)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(sectionTitle)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            if library.importing { ProgressView().controlSize(.small) }
            Spacer(minLength: 12)
            TopSearchField()
            Button { withAnimation(.smooth(duration: 0.35)) { ui.showQueue.toggle() } } label: {
                Image(systemName: "list.bullet").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).help("Queue")
            Button { showImporter = true } label: {
                Image(systemName: "plus").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).help("Add music")
        }
    }

    @ViewBuilder private var content: some View {
        switch ui.tab {
        case .nowPlaying: NowPlayingView()
        case .songs: AllSongsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .playlists: PlaylistsView()
        case .youtube: YouTubeView()
        }
    }
}

struct TopSearchField: View {
    @ObservedObject private var ui = UIState.shared
    @FocusState private var focused: Bool
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search for music…", text: $ui.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
            if !ui.searchText.isEmpty {
                Button {
                    ui.searchText = ""; ui.debouncedSearch = ""; ui.searchVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 320)
        .appGlass(in: .capsule)
        .onChange(of: ui.searchText) { _, text in
            ui.searchVisible = !text.isEmpty
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                ui.debouncedSearch = text.trimmingCharacters(in: .whitespaces)
            }
        }
        .onChange(of: ui.searchFocusToken) { _, _ in focused = true }
    }
}

// MARK: - All Songs

struct AllSongsView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        let tracks = library.tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        ScrollView {
            if tracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your library is empty").font(.headline)
                    Text("Add music with the + button, or drag files in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, ordinal: index + 1) {
                            player.play(queue: tracks, at: index)
                        } menu: {
                            Button("Play Next") { player.playNext([track]) }
                            Button("Add to Queue") { player.addToQueue([track]) }
                            Button("Get Info…") { UIState.shared.infoTrack = track }
                            AddToPlaylistMenu(trackIDs: [track.id])
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                library.removeTracks(ids: [track.id])
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 96)
            }
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var youtube = YouTubeService.shared

    private struct ArtistEntry: Identifiable {
        let name: String
        let tracks: [Track]
        let art: NSImage?
        var id: String { name }
    }

    private var artists: [ArtistEntry] {
        var groups: [String: [Track]] = [:]
        for t in library.tracks where !t.artist.isEmpty {
            groups[t.artist, default: []].append(t)
        }
        return groups.map { name, ts in
            ArtistEntry(name: name, tracks: ts,
                        art: library.artwork(for: ts.first { $0.artworkFile != nil }))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 22, alignment: .top)]

    var body: some View {
        if let selected = ui.artistSelection, let entry = artists.first(where: { $0.name == selected }) {
            detail(entry)
        } else {
            grid
        }
    }

    private var grid: some View {
        let items = artists
        return ScrollView {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.mic").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No artists yet").font(.headline)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(items) { artist in
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { ui.artistSelection = artist.name }
                        } label: {
                            VStack(spacing: 8) {
                                ArtistAvatar(localArt: artist.art, remote: youtube.artistImage(for: artist.name))
                                    .frame(width: 110, height: 110)
                                Text(artist.name).font(.callout).lineLimit(1)
                                Text("\(artist.tracks.count) songs")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .task(id: youtube.ready) { youtube.loadArtistImage(name: artist.name) }
                    }
                }
                .padding(24).padding(.bottom, 96)
            }
        }
    }

    private func detail(_ entry: ArtistEntry) -> some View {
        let albums = library.albums.filter { $0.artist == entry.name }
        let sortedTracks = entry.tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let profile = youtube.profile(for: entry.name)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(entry, albums: albums, sortedTracks: sortedTracks, profile: profile)

                // Bio from YouTube Music.
                if let bio = profile?.bio, !bio.isEmpty {
                    ArtistBio(text: bio).padding(.horizontal, 28)
                } else if youtube.artistProfileLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading artist info…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                }

                if !albums.isEmpty {
                    sectionHeader("Albums in Your Library")
                    horizontalCards {
                        ForEach(albums) { album in
                            AlbumCard(album: album, open: {
                                ui.albumSelection = album.id
                                withAnimation(.smooth(duration: 0.3)) { ui.tab = .albums }
                            }, edit: {})
                            .frame(width: 150)
                        }
                    }
                }

                if !sortedTracks.isEmpty {
                    sectionHeader("Songs in Your Library")
                    LazyVStack(spacing: 2) {
                        ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, ordinal: index + 1) {
                                player.play(queue: sortedTracks, at: index)
                            } menu: {
                                Button("Play Next") { player.playNext([track]) }
                                Button("Add to Queue") { player.addToQueue([track]) }
                                Button("Get Info…") { UIState.shared.infoTrack = track }
                                AddToPlaylistMenu(trackIDs: [track.id])
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                // ── From YouTube Music ──
                if let profile {
                    if !profile.topSongs.isEmpty {
                        sectionHeader("Popular on YouTube")
                        LazyVStack(spacing: 3) {
                            ForEach(profile.topSongs) { song in
                                YTResultRow(result: song,
                                            onPlay: { youtube.play(song) },
                                            onDownload: { youtube.download(song) },
                                            onAdd: { youtube.addToLibrary(song) })
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    if !profile.albums.isEmpty {
                        sectionHeader("Albums on YouTube")
                        horizontalCards { ForEach(profile.albums) { YTAlbumCard(album: $0) } }
                    }
                    if !profile.singles.isEmpty {
                        sectionHeader("Singles & EPs on YouTube")
                        horizontalCards { ForEach(profile.singles) { YTAlbumCard(album: $0) } }
                    }
                }
            }
            .padding(.bottom, 96)
        }
        .task(id: "\(entry.name)|\(youtube.ready)") { youtube.loadArtistProfile(name: entry.name) }
    }

    /// Spotify-style hero: the artist's YouTube photo as a full-bleed banner,
    /// with the name + Play overlaid and a scrim blending into the content.
    private func hero(_ entry: ArtistEntry, albums: [Album], sortedTracks: [Track],
                      profile: YTArtistDetail?) -> some View {
        // YouTube's artist photo is delivered square ("=w544-h544"), but it's a
        // centre-crop of the same wide immersive-header image shown atop YT
        // Music artist pages. Re-requesting it as a 1920×800 crop yields the
        // full cinematic band shot, which fills the banner edge-to-edge like
        // Apple Music's header. Fall back to the square photo, then local art.
        let artistPhoto = profile?.thumb ?? youtube.artistImage(for: entry.name)
        let bannerURL = Self.widen(artistPhoto)
        let bannerFallback = artistPhoto
        let height: CGFloat = 420
        return ZStack(alignment: .bottomLeading) {
            // A fixed-size clear rectangle is the layout "skeleton"; the photo is
            // painted into it as an overlay, so the image fills/crops to the
            // banner (re-cropping on resize) and can never drive the layout size.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    RemoteArtwork(url: bannerURL, fallback: bannerFallback) {
                        heroLocal(entry.art, fit: false)
                    }
                }
                .clipped()
            // Darken the top (so the photo blends into the top bar above) and the
            // bottom (so the title stays legible).
            .overlay(
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0.0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.55), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            )
            // Feather the bottom to transparent so it dissolves into the panel.
            .mask(
                LinearGradient(stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.74),
                    .init(color: .white.opacity(0.0), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            )

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ARTIST")
                        .font(.caption2.weight(.bold)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(entry.name)
                        .font(.system(size: 46, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                    Text(headerSubtitle(entry: entry, albums: albums, profile: profile))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                }
                Spacer()
                playButton(sortedTracks: sortedTracks, profile: profile)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 56)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { ui.artistSelection = nil }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32).contentShape(Circle())
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .padding(16)
        }
        .task(id: youtube.ready) { youtube.loadArtistImage(name: entry.name) }
    }

    /// Rewrites a googleusercontent/ggpht image URL to request a wide (1920×800)
    /// crop instead of the default square, exposing the artist's cinematic
    /// immersive-header image.
    static func widen(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let s = url.absoluteString
        if let r = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w1920-h800"))
        }
        if let r = s.range(of: #"=s\d+"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w1920-h800"))
        }
        return url
    }

    @ViewBuilder private func heroLocal(_ localArt: NSImage?, fit: Bool) -> some View {
        if let localArt {
            if fit { Image(nsImage: localArt).resizable().scaledToFit() }
            else { Image(nsImage: localArt).resizable().scaledToFill() }
        } else {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder private func playButton(sortedTracks: [Track], profile: YTArtistDetail?) -> some View {
        if !sortedTracks.isEmpty {
            Button { player.play(queue: sortedTracks, at: 0) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent).controlSize(.large)
        } else if let top = profile?.topSongs, !top.isEmpty {
            Button { youtube.play(top[0]) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private func headerSubtitle(entry: ArtistEntry, albums: [Album], profile: YTArtistDetail?) -> String {
        var parts: [String] = []
        if !entry.tracks.isEmpty { parts.append("\(entry.tracks.count) in library") }
        if let subs = profile?.subscribers, !subs.isEmpty { parts.append("\(subs) subscribers") }
        return parts.isEmpty ? "\(entry.tracks.count) songs · \(albums.count) albums"
                             : parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal, 28).padding(.top, 2)
    }

    private func horizontalCards<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) { content() }
                .padding(.horizontal, 28)
        }
    }
}

/// Collapsible artist biography from YouTube Music.
/// Circular artist avatar: the YouTube Music photo when available, otherwise
/// the artist's local album art, otherwise a person glyph.
struct ArtistAvatar: View {
    let localArt: NSImage?
    let remote: URL?

    var body: some View {
        RemoteArtwork(url: remote, fallback: nil) { placeholder }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder private var placeholder: some View {
        if let localArt {
            Image(nsImage: localArt).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct ArtistBio: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 160 {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var youtube = YouTubeService.shared
    @ObservedObject private var ui = UIState.shared

    /// Re-fires lyrics loading when the track or the toggle changes.
    private var lyricsKey: String {
        "\(player.current?.id.uuidString ?? "")|\(settings.showLyrics)"
    }

    private var triviaKey: String {
        "\(player.current?.id.uuidString ?? "")|\(settings.geniusToken.isEmpty)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            playerColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if player.current != nil {
                sidePanel
                    .frame(width: 290)
                    .padding(.trailing, 24)
                    .padding(.vertical, 24)
            }
        }
        .background(GestureCatcher())
        .task(id: lyricsKey) {
            if settings.showLyrics, let track = player.current {
                youtube.loadLyrics(for: track)
            } else {
                youtube.clearLyrics()
            }
        }
        .task(id: triviaKey) {
            if let track = player.current {
                youtube.loadTrivia(for: track)
            } else {
                youtube.clearTrivia()
            }
        }
    }

    private var playerColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            if let track = player.current {
                VStack(spacing: 26) {
                    ArtworkCard(artwork: library.artwork(for: track),
                                remote: track.remoteArtworkURL,
                                remoteFallback: track.remoteArtworkFallbackURL)
                        .frame(width: 280, height: 280)
                        .scaleEffect(ui.artZoom)
                        .animation(.smooth(duration: 0.25), value: ui.artZoom)
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            Text(track.title)
                                .font(.title2.weight(.semibold))
                                .lineLimit(1)
                            if player.bitPerfectActive {
                                Text("BIT-PERFECT")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.15), in: .capsule)
                                    .help("Device sample rate matched to the file — untouched signal path")
                            }
                        }
                        Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 340)

                    if settings.showLyrics {
                        lyricsArea
                    }
                }
                Spacer(minLength: 16)
                transport
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .font(.title3.weight(.medium))
                    Button("Browse Library") { UIState.shared.tab = .albums }
                        .buttonStyle(.glass)
                }
                .padding(.vertical, 48)
                .padding(.horizontal, 64)
                .appGlass(in: .rect(cornerRadius: 26))
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
    }

    // MARK: Up Next + Song Trivia side panel

    private var upcoming: [(Int, Track)] {
        guard let ci = player.currentIndex else { return [] }
        return player.tracks.enumerated().filter { $0.offset > ci }.map { ($0.offset, $0.element) }
    }

    private var sidePanel: some View {
        VStack(spacing: 14) {
            upNextCard
            triviaCard
        }
    }

    private var upNextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Button { player.setAutoplayRadio(!player.autoplayRadio) } label: {
                    Image(systemName: "infinity")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .foregroundStyle(player.autoplayRadio ? Color.accentColor : .secondary)
                .help(player.autoplayRadio ? "Autoplay related: on" : "Keep playing related music forever")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if upcoming.isEmpty {
                Text(player.autoplayRadio ? "Finding related tracks…" : "Nothing queued")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(upcoming, id: \.0) { idx, track in
                            upNextRow(track, index: idx)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        .appGlass(in: .rect(cornerRadius: 18))
    }

    private func upNextRow(_ track: Track, index: Int) -> some View {
        Button { player.play(at: index) } label: {
            HStack(spacing: 10) {
                ArtworkSquare(image: library.artwork(for: track), corner: 6,
                              remote: track.remoteArtworkURL, remoteFallback: track.remoteArtworkFallbackURL)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.callout).lineLimit(1)
                    Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var triviaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Song Trivia").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
            }
            if youtube.triviaLoading {
                HStack { ProgressView().controlSize(.small); Text("Looking it up…").font(.caption).foregroundStyle(.secondary) }
            } else if let t = youtube.trivia {
                Text(t.text)
                    .font(.callout).foregroundStyle(.primary)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                if !t.subtitle.isEmpty {
                    Text(t.subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
                if !t.url.isEmpty {
                    Button { openExternal(t.url) } label: {
                        Label("Read on \(t.source)", systemImage: "arrow.up.right.square").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else {
                Text("No info found for this track.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        .appGlass(in: .rect(cornerRadius: 18))
    }

    private func openExternal(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    @ViewBuilder private var lyricsArea: some View {
        if youtube.lyricsLoading {
            ProgressView().controlSize(.small).padding(.top, 12)
        } else if let ly = youtube.lyrics, ly.synced {
            LyricsStrip(lyrics: ly).padding(.top, 10)
        } else if let ly = youtube.lyrics, !ly.plain.isEmpty {
            Text("Lyrics aren’t time-synced for this track")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 12)
        }
    }

    private var transport: some View {
        VStack(spacing: 18) {
            TransportProgress()

            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 6) {
                    Button { withAnimation(.bouncy(duration: 0.3)) { player.toggleShuffle() } } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .scaleEffect(player.shuffling ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(player.shuffling ? .primary : .tertiary)
                    .help("Shuffle")

                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { withAnimation(.bouncy(duration: 0.3)) { player.cycleRepeat() } } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace))
                            .scaleEffect(player.repeatMode != .off ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(player.repeatMode != .off ? .primary : .tertiary)
                    .help("Repeat")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .appGlass(in: .capsule, interactive: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(.white.opacity(0.7))
                    .frame(width: 140)
                    .onChange(of: player.volume) { old, new in
                        // Haptic detents at 0%, 50%, 100%.
                        for (mark, pattern) in [(0.0, NSHapticFeedbackManager.FeedbackPattern.levelChange),
                                                (0.5, .generic), (1.0, .levelChange)] {
                            if (old < mark && new >= mark) || (old > mark && new <= mark) {
                                Haptics.tap(pattern)
                            }
                        }
                    }
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button { MiniPlayerController.shared.toggle() } label: {
                    Image(systemName: "pip")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Mini player (.)")
                .padding(.leading, 6)
            }
        }
    }
}

/// Compact karaoke-style lyrics for Now Playing: the current line highlighted
/// with the next line dimmed below, advancing with playback.
struct LyricsStrip: View {
    let lyrics: Lyrics
    @ObservedObject private var clock = PlaybackClock.shared

    private var currentIndex: Int {
        let t = clock.elapsed + 0.25   // small lead so lines land on the beat
        var idx = 0
        for (i, line) in lyrics.lines.enumerated() {
            if line.time <= t { idx = i } else { break }
        }
        return idx
    }

    private func display(_ line: LyricLine) -> String {
        line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.text
    }

    var body: some View {
        let idx = min(currentIndex, lyrics.lines.count - 1)
        VStack(spacing: 5) {
            Text(display(lyrics.lines[idx]))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if idx + 1 < lyrics.lines.count {
                Text(display(lyrics.lines[idx + 1]))
                    .font(.callout)
                    .foregroundStyle(.secondary.opacity(0.55))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 440, minHeight: 56)
        .id(idx)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.smooth(duration: 0.3), value: idx)
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ui = UIState.shared
    @State private var editingAlbum: Album?

    var body: some View {
        Group {
            if let id = ui.albumSelection, let album = library.albums.first(where: { $0.id == id }) {
                AlbumDetailView(album: album,
                                back: { withAnimation(.smooth(duration: 0.3)) { ui.albumSelection = nil } },
                                edit: { editingAlbum = album })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if library.tracks.isEmpty {
                VStack {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "music.note")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Drop music here")
                            .font(.title3.weight(.medium))
                        Text("or press + to add files or folders")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 48)
                    .padding(.horizontal, 64)
                    .appGlass(in: .rect(cornerRadius: 26))
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Group {
                            if ui.recentlyAddedOnly {
                                Button { withAnimation(.smooth(duration: 0.25)) { ui.recentlyAddedOnly = false } } label: {
                                    Label("Recently Added", systemImage: "clock.fill")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.glassProminent)
                            } else {
                                Button { withAnimation(.smooth(duration: 0.25)) { ui.recentlyAddedOnly = true } } label: {
                                    Label("Recently Added", systemImage: "clock")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        Spacer()
                        Menu {
                            Picker("Sort By", selection: $settings.albumSort) {
                                ForEach(AlbumSort.allCases) { sort in
                                    Text(sort.label).tag(sort)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(settings.albumSort.label, systemImage: "arrow.up.arrow.down")
                                .font(.caption.weight(.semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .appGlass(in: .capsule)
                        .opacity(ui.recentlyAddedOnly ? 0.45 : 1)
                        .disabled(ui.recentlyAddedOnly)
                        .help("Sort albums")
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24)],
                                  alignment: .leading, spacing: 26) {
                            ForEach(displayedAlbums) { album in
                                AlbumCard(album: album,
                                          selected: ui.albumMultiSelection.contains(album.id),
                                          open: { handleClick(album) },
                                          edit: { editingAlbum = album })
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 96)
                    }
                }
                .transition(.opacity)
                .overlay(alignment: .bottom) {
                    if !ui.albumMultiSelection.isEmpty {
                        AlbumSelectionBar()
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .sheet(item: $editingAlbum) { album in
            EditAlbumSheet(album: album) { newKey in
                if ui.albumSelection != nil { ui.albumSelection = newKey }
            }
        }
    }

    /// Grid order under the active sort / recently-added filter.
    private var displayedAlbums: [Album] {
        let all = library.albums   // base: name-sorted
        if ui.recentlyAddedOnly {
            return Array(all.sorted { $0.dateAdded > $1.dateAdded }.prefix(24))
        }
        switch settings.albumSort {
        case .name:
            return all
        case .artist:
            return all.sorted {
                let cmp = $0.artist.localizedStandardCompare($1.artist)
                return cmp == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                           : cmp == .orderedAscending
            }
        case .dateAdded:
            return all.sorted { $0.dateAdded > $1.dateAdded }
        case .mostPlayed:
            return all.sorted {
                $0.playCount != $1.playCount ? $0.playCount > $1.playCount
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .relevance:
            return all.sorted { relevance($0) > relevance($1) }
        }
    }

    /// Plays + how recently played + how recently added.
    private func relevance(_ album: Album) -> Double {
        var score = Double(album.playCount) * 3
        if let lastPlayed = album.lastPlayed {
            let days = -lastPlayed.timeIntervalSinceNow / 86400
            score += max(0, 20 - days)
        }
        let daysAdded = -album.dateAdded.timeIntervalSinceNow / 86400
        score += max(0, 10 - daysAdded / 3)
        return score
    }

    /// Finder-style click handling: ⌘ toggles, ⇧ extends a range from the
    /// anchor, plain click opens (clearing any selection).
    private func handleClick(_ album: Album) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            withAnimation(.smooth(duration: 0.15)) {
                if ui.albumMultiSelection.contains(album.id) {
                    ui.albumMultiSelection.remove(album.id)
                } else {
                    ui.albumMultiSelection.insert(album.id)
                    ui.albumSelectionAnchor = album.id
                }
            }
        } else if mods.contains(.shift) {
            let albums = displayedAlbums
            guard let clicked = albums.firstIndex(where: { $0.id == album.id }) else { return }
            let anchorIdx = ui.albumSelectionAnchor.flatMap { a in albums.firstIndex { $0.id == a } } ?? clicked
            let range = min(anchorIdx, clicked)...max(anchorIdx, clicked)
            withAnimation(.smooth(duration: 0.15)) {
                ui.albumMultiSelection.formUnion(albums[range].map(\.id))
            }
            if ui.albumSelectionAnchor == nil { ui.albumSelectionAnchor = album.id }
        } else {
            if !ui.albumMultiSelection.isEmpty {
                withAnimation(.smooth(duration: 0.15)) { ui.albumMultiSelection = [] }
            }
            ui.albumSelectionAnchor = album.id
            withAnimation(.smooth(duration: 0.3)) { ui.albumSelection = album.id }
        }
    }
}

/// Bulk actions for the current multi-selection.
struct AlbumSelectionBar: View {
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared

    private var selectedTracks: [Track] {
        library.albums
            .filter { ui.albumMultiSelection.contains($0.id) }
            .flatMap(\.tracks)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(ui.albumMultiSelection.count) selected")
                .font(.caption.weight(.semibold))
            Divider().frame(height: 16)
            Button { Player.shared.play(queue: selectedTracks, at: 0) } label: {
                Label("Play", systemImage: "play.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            Button { Player.shared.playNext(selectedTracks) } label: {
                Text("Play Next").font(.caption)
            }
            .buttonStyle(.glass)
            Button { Player.shared.addToQueue(selectedTracks) } label: {
                Text("Add to Queue").font(.caption)
            }
            .buttonStyle(.glass)
            Menu {
                AddToPlaylistMenu(trackIDs: selectedTracks.map(\.id))
                Divider()
                Button("Remove from Library", role: .destructive) {
                    library.removeTracks(ids: Set(selectedTracks.map(\.id)))
                    ui.albumMultiSelection = []
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            Button {
                withAnimation(.smooth(duration: 0.2)) { ui.albumMultiSelection = [] }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Clear selection (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .appGlass(in: .capsule, interactive: true)
    }
}

struct AlbumCard: View {
    let album: Album
    var selected: Bool = false
    let open: () -> Void
    let edit: () -> Void
    @ObservedObject private var library = Library.shared
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkSquare(image: library.artwork(for: album), corner: 12,
                          remote: album.remoteArtworkURL, remoteFallback: album.remoteArtworkFallbackURL)
                .overlay(alignment: .bottomTrailing) {
                    if hovered {
                        Button { Player.shared.play(queue: album.tracks, at: 0) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .shadow(color: .black.opacity(hovered ? 0.4 : 0.2), radius: hovered ? 14 : 8, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2.5)
                )
                .overlay(alignment: .topLeading) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.black, .white)
                            .padding(7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(album.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .opacity(selected ? 0.92 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.smooth(duration: 0.18)) { hovered = h } }
        .contextMenu {
            Button("Play") { Player.shared.play(queue: album.tracks, at: 0) }
            Button("Play Next") { Player.shared.playNext(album.tracks) }
            Button("Add to Queue") { Player.shared.addToQueue(album.tracks) }
            AddToPlaylistMenu(trackIDs: album.tracks.map(\.id))
            Button("Edit Album…") { edit() }
            Divider()
            Button("Remove from Library", role: .destructive) {
                library.removeTracks(ids: Set(album.tracks.map(\.id)))
            }
        }
    }
}

/// Universal circular glass back button used across detail screens.
struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button { withAnimation(.smooth(duration: 0.28)) { action() } } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("Back")
    }
}

struct AlbumDetailView: View {
    let album: Album
    let back: () -> Void
    let edit: () -> Void
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackButton(action: back)
                .padding(.horizontal, 28)
                .padding(.top, 16)
            header
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 14)
            ScrollView {
                let anyNumbered = album.tracks.contains { $0.trackNumber != nil }
                LazyVStack(spacing: 2) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, ordinal: index + 1,
                                 ordinalText: track.trackNumber.map(String.init) ?? (anyNumbered ? "‒" : nil)) {
                            player.play(queue: album.tracks, at: index)
                        } menu: {
                            Button("Play Next") { player.playNext([track]) }
                            Button("Add to Queue") { player.addToQueue([track]) }
                            Divider()
                            Button("Move Up") { library.moveTrack(inAlbum: album.id, id: track.id, by: -1) }
                                .disabled(index == 0)
                            Button("Move Down") { library.moveTrack(inAlbum: album.id, id: track.id, by: 1) }
                                .disabled(index == album.tracks.count - 1)
                            Button("Number Tracks in This Order") { library.applyTrackNumbers(album.tracks) }
                            Divider()
                            Button("Get Info…") { UIState.shared.infoTrack = track }
                            AddToPlaylistMenu(trackIDs: [track.id])
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                library.removeTracks(ids: [track.id])
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ArtworkSquare(image: library.artwork(for: album), corner: 12,
                          remote: album.remoteArtworkURL, remoteFallback: album.remoteArtworkFallbackURL)
                .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(album.artist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text("\(album.tracks.count) songs · \(Int(album.tracks.reduce(0) { $0 + $1.duration } / 60)) min")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        Player.shared.play(queue: album.tracks, at: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    Button { edit() } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }
}

// MARK: - Edit album sheet

struct EditAlbumSheet: View {
    let album: Album
    let onSave: (String) -> Void
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var artist: String
    @State private var newArtwork: NSImage?
    @State private var newArtworkData: Data?
    @State private var showImagePicker = false

    init(album: Album, onSave: @escaping (String) -> Void) {
        self.album = album
        self.onSave = onSave
        _name = State(initialValue: album.name)
        let synthesized = album.artist == "Unknown Artist" || album.artist == "Various Artists"
        _artist = State(initialValue: synthesized ? "" : album.artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Album")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    ArtworkSquare(image: newArtwork ?? library.artwork(for: album), corner: 14,
                                  remote: album.remoteArtworkURL, remoteFallback: album.remoteArtworkFallbackURL)
                        .frame(width: 120, height: 120)
                    Button("Choose Image…") { showImagePicker = true }
                        .buttonStyle(.glass)
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Album")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Album name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Album Artist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Artist", text: $artist)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let newKey = library.updateAlbum(key: album.id, name: name,
                                                        artist: artist, artworkData: newArtworkData) {
                        onSave(newKey)
                    }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result,
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                newArtwork = image
                newArtworkData = data
            }
        }
    }
}

// MARK: - Settings sheet

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, playback, equalizer, library, youtube
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .playback: return "Playback"
        case .equalizer: return "Equalizer"
        case .library: return "Library"
        case .youtube: return "YouTube Music"
        }
    }
    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .playback: return "slider.horizontal.3"
        case .equalizer: return "waveform"
        case .library: return "folder"
        case .youtube: return "play.rectangle.fill"
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var watcher = FolderWatcher.shared
    @ObservedObject private var youtube = YouTubeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    @State private var category: SettingsCategory = .appearance

    @ViewBuilder private var youtubeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("YouTube Music")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { youtube.enabled },
                    set: { on in
                        youtube.enabled = on
                        if !on, UIState.shared.tab == .youtube { UIState.shared.tab = .albums }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            Text("Adds a YouTube tab to search, stream, and download music. Streaming needs an internet connection; downloads replay offline.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if youtube.enabled {
                switch youtube.tool {
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking setup…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .ready(let version, let ffmpeg):
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("yt-dlp \(version) · music library ready")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !ffmpeg {
                        Text("ffmpeg missing — downloads won’t embed cover art.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text("Downloads saved to ~/Music/Mute/YouTube.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .missing(let detail):
                    if youtube.installing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("Missing: \(detail)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Install") { youtube.install() }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                        Text("Installs yt-dlp + ffmpeg via Homebrew and ytmusicapi in a Python venv.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryNav
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch category {
                    case .appearance: appearancePanel
                    case .playback: playbackPanel
                    case .equalizer: equalizerPanel
                    case .library: libraryPanel
                    case .youtube: youtubeSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 660, height: 470)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(14)
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { watcher.add(url) }
        }
    }

    // MARK: Category nav

    private var categoryNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MUTE")
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.tertiary)
            Text("Settings")
                .font(.title3.weight(.bold))
                .padding(.bottom, 12)
            ForEach(SettingsCategory.allCases) { cat in
                Button { category = cat } label: {
                    HStack(spacing: 10) {
                        Image(systemName: cat.icon).font(.system(size: 13)).frame(width: 18)
                        Text(cat.label).font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(category == cat ? AnyShapeStyle(.white.opacity(0.13)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(category == cat ? .primary : .secondary)
            }
            Spacer()
            Button("Reset to Defaults") { settings.reset() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.2))
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Panels

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader("Appearance")
            VStack(alignment: .leading, spacing: 8) {
                Text("Glass").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $settings.glassStyle) {
                    ForEach(GlassStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Text("Frost").font(.callout)
                    Slider(value: $settings.frost, in: 0...1)
                    Text("\(Int(settings.frost * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Background").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $settings.backdropMode) {
                    ForEach(BackdropMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if settings.backdropMode == .glass {
                    caption("The window itself turns to glass — whatever is behind it frosts through.")
                }
                ColorPicker("Background color", selection: $settings.backgroundColor, supportsOpacity: false)
                    .disabled(settings.backdropMode == .glass)
                    .opacity(settings.backdropMode == .glass ? 0.4 : 1)
            }
        }
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader("Playback")
            HStack {
                Text("Crossfade").font(.callout)
                Slider(value: $settings.crossfade, in: 0...12, step: 0.5)
                Text(settings.crossfade == 0 ? "Gapless" : String(format: "%.1fs", settings.crossfade))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            caption("At 0, tracks join sample-accurately with no gap.")
            HStack {
                Text("Loudness Normalization").font(.callout)
                Spacer()
                Picker("", selection: $settings.normalizationMode) {
                    ForEach(NormalizationMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            caption("EBU R128: levels every track toward −23 LUFS (press L).")
            Toggle("Bit-perfect output", isOn: $settings.bitPerfect)
            caption("Drives the DAC at the file's sample rate and bypasses EQ, loudness and crossfade (press B).")
            Toggle("Show synced lyrics", isOn: $settings.showLyrics)
            caption("Karaoke-style real-time lyrics on Now Playing for YouTube tracks, when available.")
            HStack {
                Text("Genius token (optional)").font(.callout)
                TextField("For per-song facts", text: $settings.geniusToken)
                    .textFieldStyle(.roundedBorder)
            }
            caption("Song Trivia works out of the box (artist info). Add a free token from genius.com/api-clients for richer per-song facts.")
        }
    }

    private var equalizerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader("Equalizer")
                Spacer()
                Toggle("", isOn: $settings.eqEnabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            EQBands()
                .disabled(!settings.eqEnabled)
                .opacity(settings.eqEnabled ? 1 : 0.45)
        }
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader("Watched Folders")
                Spacer()
                Button { showFolderPicker = true } label: {
                    Label("Add Folder", systemImage: "plus").font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass).controlSize(.small)
            }
            ForEach(watcher.folders, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { watcher.remove(path) } label: {
                        Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if watcher.folders.isEmpty {
                caption("New audio files in watched folders (e.g. your DAW bounces) are imported automatically.")
            }
        }
    }
}

struct EQBands: View {
    @ObservedObject private var settings = Settings.shared
    private static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    /// Matches the current gains to a named preset, or "Custom" if hand-tuned.
    private var presetSelection: Binding<String> {
        Binding(
            get: { EQPreset.all.first { $0.gains == settings.eqGains }?.name ?? "Custom" },
            set: { name in
                if let preset = EQPreset.all.first(where: { $0.name == name }) {
                    withAnimation(.smooth(duration: 0.3)) { settings.eqGains = preset.gains }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Preset")
                    .font(.callout)
                Spacer()
                Picker("", selection: presetSelection) {
                    ForEach(EQPreset.all) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                    if !EQPreset.all.contains(where: { $0.gains == settings.eqGains }) {
                        Text("Custom").tag("Custom")
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .padding(.bottom, 2)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 5) {
                        Slider(value: $settings.eqGains[i], in: -12...12)
                            .frame(width: 86)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 24, height: 86)
                            .controlSize(.mini)
                            .tint(.white.opacity(0.75))
                        Text(Self.labels[i])
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            HStack {
                Text("±12 dB")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Flat") { settings.eqGains = Array(repeating: 0, count: 10) }
                    .buttonStyle(.glass)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Smart search

struct SearchBarView: View {
    @ObservedObject private var ui = UIState.shared
    @FocusState private var focused: Bool
    @State private var debounceTask: Task<Void, Never>?
    @AppStorage("recentSearches") private var recentsData = "[]"

    private var recents: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentsData.utf8))) ?? []
    }

    private func saveRecent(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var list = recents.filter { $0.localizedCaseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(5))) {
            recentsData = String(decoding: data, as: UTF8.self)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search songs, artists, albums", text: $ui.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { saveRecent(ui.searchText) }
                if !ui.searchText.isEmpty {
                    Button {
                        ui.searchText = ""
                        ui.debouncedSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .appGlass(in: .capsule)

            HStack(spacing: 6) {
                ForEach(SearchScope.allCases) { scope in
                    Button { withAnimation(.smooth(duration: 0.2)) { ui.searchScope = scope } } label: {
                        Text(scope.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ui.searchScope == scope ? AnyShapeStyle(.white.opacity(0.18))
                                                                : AnyShapeStyle(.white.opacity(0.05)),
                                        in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ui.searchScope == scope ? .primary : .secondary)
                }
                Spacer()
            }

            if focused, ui.searchText.isEmpty, !recents.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(recents, id: \.self) { term in
                        Button(term) { ui.searchText = term }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .onChange(of: ui.searchText) { _, text in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                ui.debouncedSearch = text.trimmingCharacters(in: .whitespaces)
            }
        }
        .onChange(of: ui.searchFocusToken) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}

struct SearchResultsView: View {
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var youtube = YouTubeService.shared

    private var query: String { ui.debouncedSearch }

    private var songResults: [Track] {
        library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    private var albumResults: [Album] {
        library.albums.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    private struct ArtistHit: Identifiable {
        let name: String
        let count: Int
        let art: NSImage?
        var id: String { name }
    }

    private var artistResults: [ArtistHit] {
        var groups: [String: [Track]] = [:]
        for t in library.tracks where !t.artist.isEmpty && t.artist.localizedCaseInsensitiveContains(query) {
            groups[t.artist.lowercased(), default: []].append(t)
        }
        return groups.values
            .map { ts in ArtistHit(name: ts[0].artist, count: ts.count,
                                   art: library.artwork(for: ts.first { $0.artworkFile != nil })) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        Group {
            switch youtube.route {
            case .artist(_, let name):
                VStack(spacing: 0) { ytDetailBar(name, kind: "Artist"); YTArtistView() }
            case .album(_, let title):
                VStack(spacing: 0) { ytDetailBar(title, kind: "Album"); YTAlbumView() }
            case .search:
                resultsList
            }
        }
        // Drive the YouTube search off the same query as the library search.
        .task(id: query) {
            youtube.query = query
            youtube.search()
        }
    }

    private func ytDetailBar(_ title: String, kind: String) -> some View {
        HStack(spacing: 12) {
            BackButton { youtube.back() }
            VStack(alignment: .leading, spacing: 0) {
                Text(kind).font(.caption2).foregroundStyle(.tertiary)
                Text(title).font(.headline).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var resultsList: some View {
        let scope = ui.searchScope
        let songs = (scope == .all || scope == .songs) ? Array(songResults.prefix(60)) : []
        let albums = (scope == .all || scope == .albums) ? albumResults : []
        let artists = scope == .all ? Array(artistResults.prefix(12)) : []
        let libEmpty = songs.isEmpty && albums.isEmpty && artists.isEmpty
        let ytEmpty = youtube.artists.isEmpty && youtube.albums.isEmpty && youtube.songs.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if libEmpty && ytEmpty && !youtube.searching {
                    HStack {
                        Spacer()
                        Text("No results for “\(query)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 40)
                        Spacer()
                    }
                }

                // ───────── In your library ─────────
                if !artists.isEmpty {
                    sectionHeader("Artists", count: artists.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(artists) { artist in
                                Button { ui.searchText = artist.name; ui.searchScope = .all } label: {
                                    VStack(spacing: 6) {
                                        ArtworkSquare(image: artist.art, corner: 30)
                                            .frame(width: 60, height: 60)
                                            .clipShape(Circle())
                                        Text(artist.name).font(.caption).lineLimit(1)
                                        Text("\(artist.count) songs").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(width: 84)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
                if !albums.isEmpty {
                    sectionHeader("Albums", count: albums.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(albums) { album in
                                AlbumCard(album: album, open: {
                                    ui.albumSelection = album.id
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        ui.searchVisible = false
                                        ui.searchText = ""
                                        ui.debouncedSearch = ""
                                        ui.tab = .albums
                                    }
                                }, edit: {})
                                .frame(width: 150)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
                if !songs.isEmpty {
                    sectionHeader("Songs", count: songResults.count)
                    LazyVStack(spacing: 2) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, ordinal: index + 1) {
                                player.play(queue: songs, at: index)
                            } menu: {
                                Button("Play Next") { player.playNext([track]) }
                                Button("Add to Queue") { player.addToQueue([track]) }
                                Button("Get Info…") { UIState.shared.infoTrack = track }
                                AddToPlaylistMenu(trackIDs: [track.id])
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                // ───────── From YouTube ─────────
                youtubeSection
            }
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
    }

    @ViewBuilder private var youtubeSection: some View {
        if youtube.ready {
            if youtube.searching && youtube.artists.isEmpty && youtube.albums.isEmpty && youtube.songs.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 24)
            }
            if !youtube.artists.isEmpty {
                sectionHeader("Artists on YouTube", count: youtube.artists.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) { ForEach(youtube.artists) { YTArtistCircle(artist: $0) } }
                        .padding(.horizontal, 28)
                }
            }
            if !youtube.albums.isEmpty {
                sectionHeader("Albums on YouTube", count: youtube.albums.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) { ForEach(youtube.albums) { YTAlbumCard(album: $0) } }
                        .padding(.horizontal, 24)
                }
            }
            if !youtube.songs.isEmpty {
                sectionHeader("Songs on YouTube", count: youtube.songs.count)
                LazyVStack(spacing: 3) {
                    ForEach(youtube.songs) { song in
                        YTResultRow(result: song,
                                    onPlay: { youtube.play(song) },
                                    onDownload: { youtube.download(song) },
                                    onAdd: { youtube.addToLibrary(song) })
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.white.opacity(0.12), in: .capsule)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - YouTube Music

/// The YouTube tab. A small navigation stack lives in YouTubeService: the root
/// is structured search (Artists / Albums / Songs); tapping an artist or album
/// pushes a detail screen with a back button.
struct YouTubeView: View {
    @ObservedObject private var youtube = YouTubeService.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch youtube.route {
            case .search:
                searchHeader
                if youtube.ready {
                    YTSearchResultsView()
                } else {
                    toolBanner
                    Spacer(minLength: 0)
                }
            case .artist(_, let name):
                detailBar(title: name, kind: "Artist")
                YTArtistView()
            case .album(_, let title):
                detailBar(title: title, kind: "Album")
                YTAlbumView()
            }
        }
        .padding(.top, 12)
    }

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search artists, albums and songs", text: $youtube.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { youtube.search() }
                if youtube.searching {
                    ProgressView().controlSize(.small)
                } else if !youtube.query.isEmpty {
                    Button { youtube.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .appGlass(in: .capsule)

            HStack(spacing: 6) {
                Label(youtube.online ? "Online" : "Offline",
                      systemImage: youtube.online ? "wifi" : "wifi.slash")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(youtube.online ? .green : .orange)
                Spacer()
                Text("Tap to stream · download to replay offline")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .onAppear { searchFocused = true }
    }

    private func detailBar(title: String, kind: String) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation(.smooth(duration: 0.28)) { youtube.back() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Back")
            VStack(alignment: .leading, spacing: 0) {
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var toolBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: youtube.toolChecking ? "hourglass" : "shippingbox")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(youtube.toolChecking ? "Checking setup…" : "Setup needed")
                .font(.headline)
            Text("YouTube Music needs yt-dlp (streaming & downloads) and a small music-data library; ffmpeg adds cover art.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if youtube.installing {
                ProgressView().controlSize(.small)
                ScrollView {
                    Text(youtube.installLog)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 130)
                .padding(10)
                .appGlass(in: .rect(cornerRadius: 12))
            } else if let detail = youtube.missingDetail {
                Text("Missing: \(detail).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button { youtube.install() } label: {
                    Label("Install automatically", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent)
                Text("Installs yt-dlp + ffmpeg via Homebrew and ytmusicapi in a Python venv.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }
}

// MARK: Structured search results

struct YTSearchResultsView: View {
    @ObservedObject private var youtube = YouTubeService.shared

    private var isEmpty: Bool {
        youtube.artists.isEmpty && youtube.albums.isEmpty && youtube.songs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = youtube.statusMessage {
                    YTNote(text: message, icon: "magnifyingglass")
                } else if isEmpty && !youtube.searching {
                    YTNote(text: "Search for any artist, album or song.",
                           icon: "play.rectangle.on.rectangle")
                }

                if !youtube.artists.isEmpty {
                    YTSectionHeader(title: "Artists", count: youtube.artists.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(youtube.artists) { YTArtistCircle(artist: $0) }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                if !youtube.albums.isEmpty {
                    YTSectionHeader(title: "Albums", count: youtube.albums.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(youtube.albums) { YTAlbumCard(album: $0) }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                if !youtube.songs.isEmpty {
                    YTSectionHeader(title: "Songs", count: youtube.songs.count)
                    LazyVStack(spacing: 3) {
                        ForEach(youtube.songs) { song in
                            YTResultRow(result: song,
                                        onPlay: { youtube.play(song) },
                                        onDownload: { youtube.download(song) },
                                        onAdd: { youtube.addToLibrary(song) })
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
    }
}

// MARK: Artist view (Albums + Singles/EPs)

struct YTArtistView: View {
    @ObservedObject private var youtube = YouTubeService.shared

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 16, alignment: .top)]

    var body: some View {
        Group {
            if youtube.loadingDetail {
                YTLoading()
            } else if let detail = youtube.artistDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if detail.albums.isEmpty && detail.singles.isEmpty {
                            YTNote(text: "No releases found for this artist.", icon: "opticaldisc")
                        }
                        if !detail.albums.isEmpty {
                            YTSectionHeader(title: "Albums", count: detail.albums.count)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(detail.albums) { YTAlbumCard(album: $0) }
                            }
                            .padding(.horizontal, 24)
                        }
                        if !detail.singles.isEmpty {
                            YTSectionHeader(title: "Singles & EPs", count: detail.singles.count)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(detail.singles) { YTAlbumCard(album: $0) }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 96)
                }
            } else {
                YTNote(text: "Couldn’t load this artist.", icon: "exclamationmark.triangle")
            }
        }
    }
}

// MARK: Album view (ordered tracklist)

struct YTAlbumView: View {
    @ObservedObject private var youtube = YouTubeService.shared

    var body: some View {
        Group {
            if youtube.loadingDetail {
                YTLoading()
            } else if let detail = youtube.albumDetail {
                ScrollView {
                    VStack(spacing: 16) {
                        header(detail)
                        LazyVStack(spacing: 2) {
                            ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { index, track in
                                YTResultRow(result: track,
                                            ordinal: track.trackNumber ?? (index + 1),
                                            onPlay: { youtube.playAlbum(detail, startAt: index) },
                                            onDownload: { youtube.downloadTrack(track, inAlbum: detail) },
                                            onAdd: { youtube.addToLibrary(track) })
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 96)
                }
            } else {
                YTNote(text: "Couldn’t load this album.", icon: "exclamationmark.triangle")
            }
        }
    }

    private func header(_ detail: YTAlbumDetail) -> some View {
        VStack(spacing: 12) {
            YTArt(url: detail.thumb, size: 150, corner: 12, placeholder: "opticaldisc")
            VStack(spacing: 3) {
                Text(detail.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text([detail.artist, detail.year.isEmpty ? nil : detail.year, "\(detail.tracks.count) songs"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { youtube.playAlbum(detail) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(detail.tracks.isEmpty || !youtube.online)

                Button { youtube.addAlbumToLibrary(detail) } label: {
                    Label("Add to Library", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(detail.tracks.isEmpty)

                Button { youtube.downloadAlbum(detail) } label: {
                    Label(youtube.albumDownloadInProgress ? "Downloading…" : "Download all",
                          systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glass)
                .disabled(youtube.albumDownloadInProgress || !youtube.online)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }
}

// MARK: Shared YouTube building blocks

/// Album / single card; tapping opens the tracklist.
struct YTAlbumCard: View {
    let album: YTAlbum
    @State private var hovered = false

    private var subtitle: String {
        album.year.isEmpty ? album.kind : "\(album.kind) · \(album.year)"
    }

    var body: some View {
        Button {
            YouTubeService.shared.openAlbum(id: album.id, title: album.title)
            withAnimation(.smooth(duration: 0.3)) { UIState.shared.tab = .youtube }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                YTArt(url: album.thumb, size: 132, corner: 12, placeholder: "opticaldisc")
                Text(album.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 132, alignment: .leading)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 132, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.03 : 1)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = h } }
    }
}

/// Circular artist avatar; tapping opens the artist profile.
struct YTArtistCircle: View {
    let artist: YTArtist
    @State private var hovered = false

    var body: some View {
        Button {
            YouTubeService.shared.openArtist(id: artist.id, name: artist.name)
            withAnimation(.smooth(duration: 0.3)) { UIState.shared.tab = .youtube }
        } label: {
            VStack(spacing: 7) {
                YTArt(url: artist.thumb, size: 78, corner: 39, placeholder: "person.fill")
                Text(artist.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 92)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.04 : 1)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = h } }
    }
}

/// Remote artwork with a graceful placeholder, used by cards and headers.
struct YTArt: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat
    var placeholder: String = "music.note"

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.white.opacity(0.06))
                .overlay(Image(systemName: placeholder).font(.title3).foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.08)) }
    }
}

struct YTSectionHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: .capsule)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
    }
}

struct YTNote: View {
    let text: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct YTLoading: View {
    var body: some View {
        VStack {
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One song / album-track row, with stream and download actions. When `ordinal`
/// is set it shows the track number (album tracklist); otherwise a thumbnail
/// (search results). Actions are injected so the same row serves both contexts.
struct YTResultRow: View {
    let result: YTResult
    var ordinal: Int?
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onAdd: () -> Void
    @ObservedObject private var youtube = YouTubeService.shared
    @ObservedObject private var library = Library.shared
    @State private var hovered = false

    init(result: YTResult, ordinal: Int? = nil,
         onPlay: @escaping () -> Void, onDownload: @escaping () -> Void,
         onAdd: @escaping () -> Void = {}) {
        self.result = result
        self.ordinal = ordinal
        self.onPlay = onPlay
        self.onDownload = onDownload
        self.onAdd = onAdd
    }

    private var state: DownloadState? { youtube.downloads[result.id] }
    private var downloaded: Bool {
        if case .done = state { return true }
        return youtube.isDownloaded(result.id)
    }
    private var inLibrary: Bool { library.isInLibrary(youtubeID: result.id) }

    var body: some View {
        HStack(spacing: 12) {
            if let ordinal {
                Text("\(ordinal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .center)
            } else {
                thumbnail
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !result.artist.isEmpty {
                        Text(result.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if result.duration > 0 {
                        Text(ordinal == nil && !result.artist.isEmpty ? "· \(timestamp(result.duration))"
                                                                       : timestamp(result.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            controls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovered ? AnyShapeStyle(.white.opacity(0.07)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hovered = $0 }
    }

    private var thumbnail: some View {
        AsyncImage(url: result.thumbnailURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.white.opacity(0.06))
                .overlay(Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary))
        }
        .frame(width: 58, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08)) }
    }

    @ViewBuilder private var controls: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.caption)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(downloaded ? "Play (downloaded)" : "Stream from YouTube")

        // Add to library (streaming — no download).
        if inLibrary || downloaded {
            Image(systemName: "checkmark.circle.fill")
                .font(.callout)
                .frame(width: 26, height: 26)
                .foregroundStyle(.green)
                .help("In your library")
        } else {
            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .font(.callout)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add to library (stream)")
        }

        switch state {
        case .downloading(let progress):
            Group {
                if progress < 0 { ProgressView().controlSize(.small) }
                else { CircularProgress(value: progress) }
            }
            .frame(width: 26, height: 26)
        case .failed(let message):
            Button(action: onDownload) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.caption)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Download failed — \(message). Retry?")
        case .done:
            doneBadge
        case nil:
            if downloaded {
                doneBadge
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Download to library")
            }
        }
    }

    private var doneBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
            .frame(width: 26, height: 26)
            .help("In your library")
    }
}

/// Small determinate ring used for download progress in result rows.
struct CircularProgress: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: value)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Zen mode

struct ZenModeView: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 34) {
                ZenRing()
                    .frame(width: 210, height: 210)
                VStack(spacing: 8) {
                    Text(player.current?.title ?? "Silence")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text([player.current?.artist, player.current?.album]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: " — "))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 560)
                Text("space · ⌘⇧Z to leave")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(40)
        }
    }
}

/// Progress ring isolated so only it re-renders on the 4 Hz clock.
struct ZenRing: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var clock = PlaybackClock.shared

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: player.fraction)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(timestamp(clock.elapsed))
                    .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                Text(timestamp(player.currentDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.linear(duration: 0.25), value: player.fraction)
    }
}

// MARK: - Drag to queue

struct QueueDragZones: View {
    @State private var nextTargeted = false
    @State private var laterTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            zone(label: "+ Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                 targeted: $nextTargeted) { Player.shared.playNext($0) }
            zone(label: "+ Later", systemImage: "text.line.last.and.arrowtriangle.forward",
                 targeted: $laterTargeted) { Player.shared.addToQueue($0) }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 90)
    }

    private func zone(label: String, systemImage: String, targeted: Binding<Bool>,
                      drop: @escaping ([Track]) -> Void) -> some View {
        Color.clear
            .frame(width: 54)
            .frame(maxHeight: .infinity)
            .overlay {
                if targeted.wrappedValue {
                    VStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.callout)
                        Text(label)
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                    .appGlass(in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted.wrappedValue)
            .onDrop(of: [.text], isTargeted: targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        guard let string = string as? String, let id = UUID(uuidString: string) else { return }
                        Task { @MainActor in
                            if let track = Library.shared.tracks.first(where: { $0.id == id }) {
                                drop([track])
                            }
                        }
                    }
                }
                return true
            }
    }
}

// MARK: - Track info / tag editor

struct TrackInfoSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = Library.shared

    // Text fields
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var composer: String
    @State private var grouping: String
    @State private var genre: String
    @State private var comments: String
    // Numeric fields kept as text (validated to digits)
    @State private var year: String
    @State private var trackNumber: String
    @State private var trackTotal: String
    @State private var discNumber: String
    @State private var discTotal: String
    @State private var bpm: String
    // Toggles / rating
    @State private var showComposer: Bool
    @State private var compilation: Bool
    @State private var rating: Int
    @State private var favorite: Bool

    @State private var tech: TechnicalInfo?
    @State private var saving = false
    @State private var saveError: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _albumArtist = State(initialValue: track.albumArtist ?? "")
        _composer = State(initialValue: track.composer ?? "")
        _grouping = State(initialValue: track.grouping ?? "")
        _genre = State(initialValue: track.genre ?? "")
        _comments = State(initialValue: track.comments ?? "")
        _year = State(initialValue: track.year.map(String.init) ?? "")
        _trackNumber = State(initialValue: track.trackNumber.map(String.init) ?? "")
        _trackTotal = State(initialValue: track.trackTotal.map(String.init) ?? "")
        _discNumber = State(initialValue: track.discNumber.map(String.init) ?? "")
        _discTotal = State(initialValue: track.discTotal.map(String.init) ?? "")
        _bpm = State(initialValue: track.bpm.map(String.init) ?? "")
        _showComposer = State(initialValue: track.showComposer ?? false)
        _compilation = State(initialValue: track.compilation ?? false)
        _rating = State(initialValue: track.rating ?? 0)
        _favorite = State(initialValue: track.isFavorite)
    }

    private var canWriteFile: Bool { MetadataService.canWriteTags(track.url) }
    /// Live copy so play-count / Reset reflect the library immediately.
    private var live: Track { library.tracks.first { $0.id == track.id } ?? track }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailsForm
                    Divider()
                    statsAndFile
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 480)
        .frame(maxHeight: 640)
        .preferredColorScheme(.dark)
        .task { tech = await MetadataService.technicalInfo(for: track) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkSquare(image: library.artwork(for: track), corner: 10,
                          remote: track.remoteArtworkURL, remoteFallback: track.remoteArtworkFallbackURL)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text([artist, album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(track.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { favorite.toggle() } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(favorite ? .pink : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Favorite")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: Details form

    private var detailsForm: some View {
        VStack(spacing: 8) {
            row("Title") { TextField("", text: $title).textFieldStyle(.roundedBorder) }
            row("Artist") { TextField("", text: $artist).textFieldStyle(.roundedBorder) }
            row("Album") { TextField("", text: $album).textFieldStyle(.roundedBorder) }
            row("Album Artist") { TextField("", text: $albumArtist).textFieldStyle(.roundedBorder) }
            row("Composer") { TextField("", text: $composer).textFieldStyle(.roundedBorder) }
            row("") {
                Toggle("Show composer in all views", isOn: $showComposer).font(.caption)
                Spacer(minLength: 0)
            }
            row("Grouping") { TextField("", text: $grouping).textFieldStyle(.roundedBorder) }
            row("Genre") { TextField("", text: $genre).textFieldStyle(.roundedBorder) }
            row("Year") {
                numberField($year, width: 80)
                Spacer(minLength: 0)
            }
            row("Track") {
                numberField($trackNumber)
                Text("of").font(.caption).foregroundStyle(.secondary)
                numberField($trackTotal)
                Spacer(minLength: 0)
            }
            row("Disc") {
                numberField($discNumber)
                Text("of").font(.caption).foregroundStyle(.secondary)
                numberField($discTotal)
                Spacer(minLength: 0)
            }
            row("") {
                Toggle("Album is a compilation of songs by various artists", isOn: $compilation).font(.caption)
                Spacer(minLength: 0)
            }
            row("Rating") {
                ratingStars
                Spacer(minLength: 0)
            }
            row("BPM") {
                numberField($bpm, width: 80)
                Spacer(minLength: 0)
            }
            row("Comments") {
                TextField("", text: $comments, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
    }

    private var ratingStars: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Button { rating = (rating == i) ? 0 : i } label: {
                    Image(systemName: i <= rating ? "star.fill" : "star")
                        .font(.callout)
                        .foregroundStyle(i <= rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
            if rating > 0 {
                Button("Clear") { rating = 0 }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: Stats + file info

    private var statsAndFile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Play Count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(playCountLabel)
                    .font(.caption)
                Spacer()
                Button("Reset") { library.resetPlayStats(track.id) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled((live.playCount ?? 0) == 0 && live.lastPlayed == nil)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                techRow("Codec", tech?.codec ?? "…")
                techRow("Sample Rate", tech?.sampleRateLabel ?? "…")
                techRow("Bit Rate", tech?.bitrateLabel ?? "…")
                techRow("Channels", tech?.channelsLabel ?? "…")
                techRow("Size", tech?.sizeLabel ?? "…")
                techRow("Duration", timestamp(track.duration))
            }
            .font(.caption)

            if !canWriteFile {
                Text("Writing tags into \(track.url.pathExtension.uppercased()) files isn't supported by macOS APIs — changes apply to the Mute library only.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var playCountLabel: String {
        let count = live.playCount ?? 0
        guard count > 0, let last = live.lastPlayed else { return "Never played" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "\(count) · last played \(f.localizedString(for: last, relativeTo: Date()))"
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button { save() } label: {
                if saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    @ViewBuilder private func row<Content: View>(_ labelText: String,
                                                 @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(labelText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder private func numberField(_ binding: Binding<String>, width: CGFloat = 50) -> some View {
        TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onChange(of: binding.wrappedValue) { _, value in
                let digits = value.filter(\.isNumber)
                if digits != value { binding.wrappedValue = digits }
            }
    }

    @ViewBuilder private func techRow(_ labelText: String, _ value: String) -> some View {
        GridRow {
            Text(labelText)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            Text(value)
                .gridCellColumns(3)
        }
    }

    private func save() {
        let edit = TagEdit(title: title, artist: artist, album: album, albumArtist: albumArtist,
                           genre: genre, year: Int(year),
                           trackNumber: Int(trackNumber), trackTotal: Int(trackTotal),
                           discNumber: Int(discNumber), discTotal: Int(discTotal),
                           composer: composer, showComposer: showComposer, grouping: grouping,
                           compilation: compilation, rating: rating, bpm: Int(bpm), comments: comments)
        library.updateTrackTags(id: track.id, edit: edit)
        if favorite != live.isFavorite { library.toggleFavorite(track.id) }
        guard canWriteFile else { dismiss(); return }
        saving = true
        saveError = nil
        Task {
            do {
                try await MetadataService.writeTags(edit, to: track.url)
                dismiss()
            } catch {
                saveError = "Library updated, but the file couldn't be rewritten: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ui = UIState.shared
    @State private var showFavorites = false

    var body: some View {
        if showFavorites {
            FavoritesDetailView { showFavorites = false }
        } else if let id = ui.playlistSelection, let playlist = library.playlists.first(where: { $0.id == id }) {
            PlaylistDetailView(playlist: playlist) { ui.playlistSelection = nil }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Playlists")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        ui.playlistSelection = library.createPlaylist().id
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 12)

                if library.playlists.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 38, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("No playlists yet")
                                .font(.headline)
                            Text("Right-click any song or album to add it to a playlist.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                        .padding(.horizontal, 48)
                        .appGlass(in: .rect(cornerRadius: 26))
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            if !library.favorites.isEmpty {
                                HStack(spacing: 12) {
                                    Image(systemName: "heart.fill")
                                        .font(.callout)
                                        .foregroundStyle(.pink)
                                        .frame(width: 22)
                                    Text("Favourites")
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    Text("\(library.favorites.count) songs")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                                .onTapGesture { showFavorites = true }
                            }
                            ForEach(library.playlists) { playlist in
                                PlaylistRow(playlist: playlist) { ui.playlistSelection = playlist.id }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 96)
                    }
                }
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    let open: () -> Void
    @ObservedObject private var library = Library.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(playlist.name)
                .font(.body.weight(.medium))
            Spacer()
            Text("\(playlist.trackIDs.count) songs")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovered ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Play") {
                let tracks = library.tracks(for: playlist)
                if !tracks.isEmpty { Player.shared.play(queue: tracks, at: 0) }
            }
            Divider()
            Button("Delete Playlist", role: .destructive) { library.deletePlaylist(playlist.id) }
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    let back: () -> Void
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @State private var name: String

    init(playlist: Playlist, back: @escaping () -> Void) {
        self.playlist = playlist
        self.back = back
        _name = State(initialValue: playlist.name)
    }

    var body: some View {
        let tracks = library.tracks(for: playlist)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { back() } label: {
                    Label("Playlists", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)

                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { library.renamePlaylist(playlist.id, to: name) }

                HStack(spacing: 14) {
                    Text("\(tracks.count) songs · \(Int(tracks.reduce(0) { $0 + $1.duration } / 60)) min")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        if !tracks.isEmpty { player.play(queue: tracks, at: 0) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tracks.isEmpty)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 14)

            if tracks.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("Right-click any song or album and choose “Add to Playlist”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, ordinal: index + 1) {
                                player.play(queue: tracks, at: index)
                            } menu: {
                                Button("Play Next") { player.playNext([track]) }
                                Button("Add to Queue") { player.addToQueue([track]) }
                                Button("Get Info…") { UIState.shared.infoTrack = track }
                                AddToPlaylistMenu(trackIDs: [track.id])
                                Divider()
                                Button("Remove from Playlist") {
                                    library.removeFromPlaylist(playlist.id, trackID: track.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 96)
                }
            }
        }
        .onDisappear { library.renamePlaylist(playlist.id, to: name) }
    }
}

struct FavoritesDetailView: View {
    let back: () -> Void
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        let tracks = library.favorites
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { back() } label: {
                    Label("Playlists", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                Label("Favourites", systemImage: "heart.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary, .pink)
                HStack(spacing: 14) {
                    Text("\(tracks.count) songs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        if !tracks.isEmpty { player.play(queue: tracks, at: 0) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tracks.isEmpty)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, ordinal: index + 1) {
                            player.play(queue: tracks, at: index)
                        } menu: {
                            Button("Play Next") { player.playNext([track]) }
                            Button("Add to Queue") { player.addToQueue([track]) }
                            Button("Get Info…") { UIState.shared.infoTrack = track }
                            AddToPlaylistMenu(trackIDs: [track.id])
                            Divider()
                            Button("Remove from Favourites") { library.toggleFavorite(track.id) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
            }
        }
    }
}

struct AddToPlaylistMenu: View {
    let trackIDs: [UUID]
    @ObservedObject private var library = Library.shared

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { library.add(trackIDs: trackIDs, to: playlist.id) }
            }
            if !library.playlists.isEmpty { Divider() }
            Button("New Playlist") {
                let playlist = library.createPlaylist()
                library.add(trackIDs: trackIDs, to: playlist.id)
            }
        }
    }
}

// MARK: - Shared rows & components

struct TrackRow<MenuContent: View>: View {
    let track: Track
    let ordinal: Int
    /// Overrides the leading number text (e.g. a real track number, or "‒" for
    /// an un-numbered track in a partly-numbered album). Falls back to `ordinal`.
    let ordinalText: String?
    let play: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @ObservedObject private var player = Player.shared
    @State private var hovered = false

    init(track: Track, ordinal: Int, ordinalText: String? = nil, play: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> MenuContent) {
        self.track = track
        self.ordinal = ordinal
        self.ordinalText = ordinalText
        self.play = play
        self.menu = menu
    }

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                } else {
                    Text(ordinalText ?? "\(ordinal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if hovered {
                // Proximity quick actions
                HStack(spacing: 4) {
                    Button { Library.shared.toggleFavorite(track.id) } label: {
                        Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                            .font(.caption)
                            .foregroundStyle(track.isFavorite ? .pink : .secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Favorite")
                    Button { Player.shared.playNext([track]) } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play next")
                    Menu {
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                }
                .transition(.opacity)
            } else {
                if track.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink.opacity(0.7))
                }
                Text(timestamp(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isCurrent ? AnyShapeStyle(.white.opacity(0.12))
                              : (hovered ? AnyShapeStyle(.white.opacity(0.07)) : AnyShapeStyle(.clear)),
                    in: RoundedRectangle(cornerRadius: 10))
        .scaleEffect(hovered ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onDrag { NSItemProvider(object: track.id.uuidString as NSString) }
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = h } }
        .contextMenu { menu() }
    }
}

struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let play: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "speaker.fill") : "music.note")
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if hovered {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            } else {
                Text(timestamp(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isCurrent ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { hovered = $0 }
    }
}

struct MiniBar: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 7) {
                HStack(spacing: 11) {
                    ArtworkSquare(image: library.artwork(for: player.current), corner: 9,
                                  remote: player.current?.remoteArtworkURL,
                                  remoteFallback: player.current?.remoteArtworkFallbackURL)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.current?.title ?? "")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(player.current?.artist.isEmpty == false ? player.current!.artist : "Unknown Artist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.smooth(duration: 0.32)) { UIState.shared.tab = .nowPlaying } }

                    HStack(spacing: 4) {
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 12))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15))
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.12), in: .circle)
                                .contentShape(Circle())
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 12))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                MiniProgress()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .frame(width: 410)
            .appGlass(in: .rect(cornerRadius: 26), interactive: true)
        }
    }
}

/// Thin progress line in the mini player; observes the clock in isolation.
struct MiniProgress: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var clock = PlaybackClock.shared
    @State private var hovered = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(.white.opacity(hovered ? 0.95 : 0.75))
                    .frame(width: max(2, geo.size.width * player.fraction))
            }
            .contentShape(Rectangle().inset(by: -7))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { player.seek(to: min(1, max(0, $0.location.x / geo.size.width))) }
            )
        }
        .frame(height: hovered ? 5 : 3)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.18), value: hovered)
    }
}

/// Loads remote cover art (YouTube), falling back to a secondary URL if the
/// high-res one 404s, then to the supplied placeholder.
struct RemoteArtwork<Placeholder: View>: View {
    let url: URL?
    var fallback: URL? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var useFallback = false

    var body: some View {
        AsyncImage(url: useFallback ? fallback : url,
                   transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                if !useFallback, fallback != nil {
                    placeholder().onAppear { useFallback = true }
                } else {
                    placeholder()
                }
            default:
                placeholder()
            }
        }
    }
}

struct ArtworkSquare: View {
    let image: NSImage?
    var corner: CGFloat = 12
    /// Remote cover (and fallback) used when there's no local `image`.
    var remote: URL? = nil
    var remoteFallback: URL? = nil

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let remote {
                    RemoteArtwork(url: remote, fallback: remoteFallback) { placeholder }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

struct ArtworkCard: View {
    let artwork: NSImage?
    /// Remote cover (and fallback) used when there's no local `artwork`.
    var remote: URL? = nil
    var remoteFallback: URL? = nil

    var body: some View {
        // Force a square that fills (crops) any non-square source, so YouTube's
        // 16:9 video thumbnails never letterbox the now-playing art.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else if let remote {
                    RemoteArtwork(url: remote, fallback: remoteFallback) { placeholder }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// The only view observing PlaybackClock — keeps the 4 Hz progress tick from
/// re-rendering the rest of the window.
struct TransportProgress: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var clock = PlaybackClock.shared

    var body: some View {
        VStack(spacing: 6) {
            ScrubBar(fraction: player.fraction) { player.seek(to: $0) }
            HStack {
                Text(timestamp(clock.elapsed))
                Spacer()
                Text(timestamp(player.currentDuration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
    }
}

struct ScrubBar: View {
    let fraction: Double
    let onSeek: (Double) -> Void
    @State private var hovered = false
    @State private var lastDecile = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: max(hovered ? 7 : 5, geo.size.width * fraction))
                    .shadow(color: .white.opacity(hovered ? 0.45 : 0), radius: hovered ? 5 : 0)
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(1, max(0, value.location.x / geo.size.width))
                        // Haptic detent every 10% while scrubbing.
                        let decile = Int(f * 10)
                        if decile != lastDecile {
                            lastDecile = decile
                            Haptics.tap(.alignment)
                        }
                        onSeek(f)
                    }
                    .onEnded { _ in lastDecile = -1 }
            )
        }
        .frame(height: hovered ? 7 : 5)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.2), value: hovered)
    }
}

struct Backdrop: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared

    var body: some View {
        ZStack {
            switch settings.backdropMode {
            case .color:
                LinearGradient(colors: [settings.backgroundColor.mix(with: .white, by: 0.06),
                                        settings.backgroundColor.mix(with: .black, by: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Soft cool sheen top-left so the floating glass panels have
                // something to refract — the layered look of the reference.
                RadialGradient(colors: [Color(.sRGB, red: 0.42, green: 0.45, blue: 0.62).opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 820)
            case .glass:
                // Window material shows through; even it out with gentle dimming.
                Color.black.opacity(0.18)
            case .albumArt:
                // The current cover, blurred and darkened, fills the window.
                LinearGradient(colors: [settings.backgroundColor.mix(with: .white, by: 0.04),
                                        settings.backgroundColor.mix(with: .black, by: 0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                albumArtLayer
                    .animation(.easeInOut(duration: 0.6), value: player.current?.id)
            }
            // Chromatic ambience from the artwork. Full-window (no view-bounds
            // seams) and skipped for grayscale art, where a low-chroma wash
            // just reads as banding against the backdrop.
            if let wash = chromaticWash {
                RadialGradient(colors: [wash.color, .clear],
                               center: .center, startRadius: 0, endRadius: 760)
                    .opacity(wash.opacity)
                    .animation(.easeInOut(duration: 0.6), value: player.current?.artworkFile)
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.4), value: settings.backdropMode)
    }

    private var albumArtLayer: some View {
        // A flexible Color.clear is the layout "skeleton"; the cover is painted
        // into it as an overlay so the image fills/crops to the window and can
        // never drive layout (which made the window break until a resize).
        Color.clear
            .overlay {
                Group {
                    if let art = library.artwork(for: player.current) {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else if let url = player.current?.remoteArtworkURL {
                        RemoteArtwork(url: url, fallback: player.current?.remoteArtworkFallbackURL) { Color.clear }
                    } else {
                        Color.clear
                    }
                }
                .blur(radius: 70)
                .opacity(0.85)
            }
            .clipped()
            .overlay(Color.black.opacity(0.5))
    }

    private var chromaticWash: (color: Color, opacity: Double)? {
        guard let ns = library.dominantColor(for: player.current)?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.18, b > 0.15 else { return nil }
        return (Color(nsColor: ns), 0.30 * Double(min(1, s)))
    }
}
