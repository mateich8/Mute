import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Tab: String, CaseIterable, Identifiable {
    case home, new, nowPlaying, songs, albums, artists, playlists, youtube, profile
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .new: return "square.grid.2x2.fill"
        case .nowPlaying: return "waveform"
        case .songs: return "music.note"
        case .albums: return "rectangle.stack.fill"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
        case .youtube: return "play.rectangle.fill"
        case .profile: return "person.crop.circle"
        }
    }

    var help: String {
        switch self {
        case .home: return "Home"
        case .new: return "New"
        case .nowPlaying: return "Now Playing"
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .youtube: return "YouTube"
        case .profile: return "Profile"
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var tab: Tab = .albums {
        didSet { if tab != .nowPlaying { lastLibraryTab = tab } }
    }
    /// Full-screen lyrics overlay (opened from the playing bar).
    @Published var lyricsOpen = false
    /// Hide the Now Playing side column (queue + trivia).
    @Published var npSidebarHidden = false
    /// Hide just the Song Trivia card.
    @Published var triviaHidden = false
    /// Track for which the Get Info sheet is open.
    @Published var infoTrack: Track?
    /// Where the Now Playing back button returns to.
    private(set) var lastLibraryTab: Tab = .albums
    // Smart search
    @Published var searchVisible = false
    /// True once the current screen's content has scrolled under the header.
    @Published var contentScrolled = false
    @Published var searchText = ""
    @Published var debouncedSearch = ""
    @Published var searchScope: SearchScope = .all

    /// Clears the global search (used when navigating into a tab that has its own).
    func clearSearch() { searchText = ""; debouncedSearch = ""; searchVisible = false }
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
/// Corner radius for panels and cards drawn inside the content area.
let kPanelInset: CGFloat = 8
let kPanelRadius: CGFloat = 16
/// Clearance at the top of the sidebar for the traffic lights, which now sit
/// inside the sidebar the way every system app places them.
let kTrafficLightStrip: CGFloat = 38

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

            // One continuous surface: a full-height sidebar flush to the window
            // edge with the traffic lights inside it, and the content beside it —
            // the way macOS composes a split view, rather than two cards floating
            // on a backdrop.
            HStack(spacing: 0) {
                Sidebar(showSettings: $showSettings, showImporter: $showImporter)
                MainArea(showImporter: $showImporter)
            }
            .ignoresSafeArea(.container, edges: .top)

            if ui.zenMode { ZenModeView().zIndex(10).transition(.opacity) }
            if ui.lyricsOpen { LyricsFullView().zIndex(20).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay(alignment: .trailing) { QueueDragZones() }
        .overlay(alignment: .bottom) {
            if player.current != nil, ui.tab != .nowPlaying {
                MiniBar()
                    .padding(.bottom, 22)
                    .padding(.leading, kSidebarWidth + 16)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .containerBackground(settings.windowBackground, for: .window)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showSettings = true }
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

}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var showSettings: Bool
    @Binding var showImporter: Bool
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var youtube = YouTubeService.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var profileStore = ProfileStore.shared
    @ObservedObject private var player = Player.shared
    @Namespace private var navNS

    private var librarySections: [Tab] {
        let sections: [Tab] = [.home, .new, .nowPlaying, .songs, .albums, .artists, .playlists]
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit here now, so the first label has to start
            // below them.
            Color.clear.frame(height: kTrafficLightStrip)

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
            HStack(spacing: 10) {
                Button { withAnimation(.smooth(duration: 0.25)) { ui.tab = .profile } } label: {
                    HStack(spacing: 8) {
                        SidebarAvatar(image: profileStore.avatar, size: 28)
                        Text(profileStore.profile.displayName)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Your profile")
                Spacer(minLength: 4)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 18, height: 18)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: kSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.16))
        .appGlass(in: .rect(cornerRadius: 0))
        // Hairline seam instead of a gap: the two halves read as one window.
        .overlay(alignment: .trailing) {
            Rectangle().fill(Surface.stroke).frame(width: 1)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TypeScale.eyebrow)
            .tracking(1.4)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func navRow(_ tab: Tab) -> some View {
        // The Playlists row yields the selection pill to the individual playlist
        // rows when one is open (otherwise two views claim the same pill id).
        let selected = ui.tab == tab && ui.debouncedSearch.isEmpty
            && !(tab == .playlists && ui.playlistSelection != nil)
        return Button {
            withAnimation(.smooth(duration: 0.28)) {
                ui.tab = tab
                if tab != .artists { ui.artistSelection = nil }
                if tab == .playlists { ui.playlistSelection = nil }
                clearSearch()
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.icon).font(.system(size: 13)).frame(width: 18)
                    .symbolVariant(selected ? .fill : .none)
                Text(tab.help).font(.callout)
                Spacer(minLength: 4)
                // Where the sound is, without having to open the tab.
                if tab == .nowPlaying, player.current != nil {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Chroma.current)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                if selected {
                    // The pill is where the playing album's colour reaches the
                    // sidebar — white here would read as more of the same grey.
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(Chroma.current.opacity(0.24))
                        .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                            .strokeBorder(Chroma.current.opacity(0.40), lineWidth: 1))
                        .animation(.smooth(duration: 0.6), value: player.current?.id)
                        .matchedGeometryEffect(id: "navPill", in: navNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
    }

    private func playlistRow(_ pl: Playlist) -> some View {
        let selected = ui.tab == .playlists && ui.playlistSelection == pl.id && ui.debouncedSearch.isEmpty
        return Button {
            withAnimation(.smooth(duration: 0.28)) {
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
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                if selected {
                    // The pill is where the playing album's colour reaches the
                    // sidebar — white here would read as more of the same grey.
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(Chroma.current.opacity(0.24))
                        .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                            .strokeBorder(Chroma.current.opacity(0.40), lineWidth: 1))
                        .animation(.smooth(duration: 0.6), value: player.current?.id)
                        .matchedGeometryEffect(id: "navPill", in: navNS)
                }
            }
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
    @ObservedObject private var player = Player.shared

    private var sectionTitle: String {
        if !ui.debouncedSearch.isEmpty { return "Search" }
        switch ui.tab {
        case .home: return "Home"
        case .new: return "New"
        case .nowPlaying: return "Now Playing"
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .youtube: return "YouTube"
        case .profile: return "Profile"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, kTrafficLightStrip)
                .padding(.bottom, 14)
                // The separator only exists once something has scrolled beneath
                // it — the standard macOS cue that the header is pinned.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Surface.stroke)
                        .frame(height: 1)
                        .opacity(ui.contentScrolled ? 1 : 0)
                }
            if !ui.debouncedSearch.isEmpty {
                SearchResultsView()
            } else {
                content
                    .id(ui.tab)
                    .transition(.opacity)
                    .onChange(of: ui.tab) { _, _ in ui.contentScrolled = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.10))
        // A breath of the playing album's colour where the content meets the
        // top of the window — the flattest part of the old layout.
        .background(alignment: .top) {
            LinearGradient(colors: [Chroma.current.opacity(0.13), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .animation(.smooth(duration: 0.8), value: player.current?.id)
                .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(sectionTitle)
                .font(TypeScale.page)
                .tracking(-0.4)
                .lineLimit(1)
            if library.importing { ProgressView().controlSize(.small) }
            Spacer(minLength: 12)
            // The YouTube tab has its own dedicated search field, so the
            // global one would just be redundant clutter there.
            if ui.tab != .youtube { TopSearchField() }
            Button { showImporter = true } label: {
                Image(systemName: "plus").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).help("Add music")
        }
    }

    @ViewBuilder private var content: some View {
        switch ui.tab {
        case .home: HomeView()
        case .new: NewView()
        case .nowPlaying: NowPlayingView()
        case .songs: AllSongsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .playlists: PlaylistsView()
        case .youtube: YouTubeView()
        case .profile: ProfileView()
        }
    }
}

struct TopSearchField: View {
    @ObservedObject private var ui = UIState.shared
    @FocusState private var focused: Bool
    @State private var debounce: Task<Void, Never>?
    /// Collapsed to its icon until asked for, so the header belongs to the page
    /// title rather than to an empty 320pt pill.
    @State private var expanded = false

    private func expand() {
        withAnimation(Motion.hover) { expanded = true }
        focused = true
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            if expanded {
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
        }
        .padding(.horizontal, expanded ? 12 : 9)
        .padding(.vertical, 7)
        .frame(width: expanded ? 300 : 32, alignment: .leading)
        .appGlass(in: .capsule)
        .contentShape(Capsule())
        .onTapGesture { if !expanded { expand() } }
        .help(expanded ? "" : "Search your library (⌘F)")
        .onChange(of: focused) { _, isFocused in
            // Collapse again once it's done its job and is empty.
            if !isFocused && ui.searchText.isEmpty {
                withAnimation(Motion.hover) { expanded = false }
            }
        }
        .onChange(of: ui.searchText) { _, text in
            ui.searchVisible = !text.isEmpty
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                ui.debouncedSearch = text.trimmingCharacters(in: .whitespaces)
            }
        }
        .onChange(of: ui.searchFocusToken) { _, _ in expand() }
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
                EmptyState(icon: "music.note",
                           title: "Your library is empty",
                           message: "Add music with the + button, or drag files in.")
            } else {
                MetaLine(text: "\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(Int(tracks.reduce(0) { $0 + $1.duration } / 60)) min")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, ordinal: index + 1) {
                            player.play(queue: tracks, at: index)
                        } menu: {
                            Button("Play Next") { player.playNext([track]) }
                            Button("Add to Queue") { player.addToQueue([track]) }
                            Button(track.isFavorite ? "Remove from Liked Music" : "Add to Liked Music") {
                                library.toggleFavorite(track.id)
                            }
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
        .tracksContentScroll()
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
                EmptyState(icon: "music.mic",
                           title: "No artists yet",
                           message: "Artists appear once your tracks carry artist tags.")
            } else {
                MetaLine(text: "\(items.count) artist\(items.count == 1 ? "" : "s")")
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
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
        .tracksContentScroll()
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
            // Feather BOTH the top (so the photo dissolves into the title bar above
            // instead of a hard seam) and the bottom (into the panel below).
            .mask(
                LinearGradient(stops: [
                    .init(color: Surface.quiet, location: 0.0),
                    .init(color: .white, location: 0.16),
                    .init(color: .white, location: 0.74),
                    .init(color: Surface.quiet, location: 1.0),
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
            PlayButton(kind: .prominent) { player.play(queue: sortedTracks, at: 0) }
        } else if let top = profile?.topSongs, !top.isEmpty {
            PlayButton(kind: .prominent) { youtube.play(top[0]) }
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
            .overlay(Circle().strokeBorder(Surface.stroke, lineWidth: 1))
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

// MARK: - Home (top picks + recommendations + listening stats)

struct HomeView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var youtube = YouTubeService.shared

    private var recents: [PlayEvent] { library.recentlyPlayed }
    private var mostPlayed: [Track] { Array(library.mostPlayed.prefix(10)) }
    private var topArtists: [(name: String, plays: Int)] { Array(library.topArtists.prefix(8)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                topPicksSection
                recommendationsSection
                if !recents.isEmpty { recentlyPlayedSection }
                if !mostPlayed.isEmpty { mostPlayedSection }
                if !topArtists.isEmpty { topArtistsSection }
                if recents.isEmpty && mostPlayed.isEmpty && youtube.recommendations.isEmpty {
                    emptyState
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
        // Recommendations arrive seconds after launch and add ~600pt in the
        // middle of the page; without an anchor the view slides off the top.
        .defaultScrollAnchor(.top)
        .tracksContentScroll()
        .task(id: youtube.ready) { youtube.loadRecommendations() }
        .task(id: player.current?.id) { youtube.loadRecommendations() }
    }

    private func header(_ title: String, _ eyebrow: String? = nil) -> some View {
        SectionHeader(eyebrow: eyebrow, title: title, accent: Chroma.current)
            .padding(.horizontal, 28)
    }

    // MARK: Top Picks for You (big gradient cards)

    private struct Pick: Identifiable {
        let id = UUID()
        let kicker: String, title: String, subtitle: String
        let colors: [Color], symbol: String
        let tracks: [Track]
    }

    private var picks: [Pick] {
        var out: [Pick] = []
        if !mostPlayed.isEmpty {
            let heavy = Array(library.mostPlayed.prefix(40))
            let names = mostPlayed.prefix(4).map(\.artist).filter { !$0.isEmpty }.joined(separator: ", ")
            out.append(Pick(kicker: "MADE FOR YOU", title: "Heavy Rotation",
                            // An untagged library has no artist names to list,
                            // which left the card with a blank line.
                            subtitle: names.isEmpty ? "\(heavy.count) song\(heavy.count == 1 ? "" : "s")" : names,
                            colors: [Color(red: 0.95, green: 0.55, blue: 0.15), Color(red: 0.85, green: 0.25, blue: 0.30)],
                            symbol: "flame.fill", tracks: Array(library.mostPlayed.prefix(40))))
        }
        let favs = library.tracks.filter { $0.favorite == true }
        if !favs.isEmpty {
            out.append(Pick(kicker: "MADE FOR YOU", title: "On Repeat",
                            subtitle: "The songs you love most",
                            colors: [Color(red: 0.55, green: 0.30, blue: 0.85), Color(red: 0.25, green: 0.35, blue: 0.80)],
                            symbol: "heart.fill", tracks: favs))
        }
        if let recentAlbum = recents.first.flatMap({ e in library.albums.first(where: { $0.tracks.contains(where: { $0.path == e.path }) }) }) {
            out.append(Pick(kicker: "LISTEN AGAIN", title: recentAlbum.name,
                            subtitle: recentAlbum.artist == "Unknown Artist"
                                ? "\(recentAlbum.tracks.count) song\(recentAlbum.tracks.count == 1 ? "" : "s")"
                                : recentAlbum.artist,
                            colors: [Color(red: 0.18, green: 0.55, blue: 0.45), Color(red: 0.10, green: 0.30, blue: 0.40)],
                            symbol: "memories", tracks: recentAlbum.tracks))
        }
        return out
    }

    @ViewBuilder private var topPicksSection: some View {
        let items = picks
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header("Top Picks for You", "Start here")
                // With three or more picks the first one runs full width as the
                // page's focal point and the rest sit in a shelf behind it. With
                // one or two, a hero would leave a lone tile stranded beside a
                // lot of empty panel, so they share the width evenly instead.
                if items.count >= 3 {
                    playButton(items[0], size: .hero)
                        .padding(.horizontal, 28)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(items.dropFirst()) { playButton($0, size: .tile) }
                        }
                        .padding(.horizontal, 28)
                    }
                } else {
                    HStack(spacing: 16) {
                        ForEach(items) { playButton($0, size: .wide) }
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
    }

    /// How much of the page a pick claims. `hero` is the single focal card,
    /// `wide` shares a row evenly, `tile` is the fixed-width shelf card.
    private enum PickSize {
        case hero, wide, tile
        var height: CGFloat { self == .hero ? 210 : self == .wide ? 190 : 170 }
        var corner: CGFloat { self == .tile ? 18 : 22 }
        var padding: CGFloat { self == .tile ? 18 : 24 }
        var fills: Bool { self != .tile }
        var titleFont: Font {
            switch self {
            case .hero: return .system(size: 42, weight: .heavy)
            case .wide: return .system(size: 30, weight: .heavy)
            case .tile: return .title2.weight(.heavy)
            }
        }
        var tracking: CGFloat { self == .hero ? -1.2 : self == .wide ? -0.8 : 0 }
        var symbolSize: CGFloat { self == .hero ? 200 : self == .wide ? 160 : 120 }
        var symbolOffset: CGFloat { self == .hero ? 260 : self == .wide ? 150 : 120 }
    }

    private func playButton(_ pick: Pick, size: PickSize) -> some View {
        Button { if !pick.tracks.isEmpty { player.play(queue: pick.tracks, at: 0) } } label: {
            pickCard(pick, size: size)
        }
        // A card this wide shouldn't scale like a small tile — the whole page
        // would look like it was breathing.
        .buttonStyle(PressableCard(lift: size.fills ? 1.008 : Lift.card))
    }

    private func pickCard(_ pick: Pick, size: PickSize = .tile) -> some View {
        let corner = size.corner
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: pick.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: pick.symbol)
                .font(.system(size: size.symbolSize, weight: .bold))
                .foregroundStyle(Surface.active)
                .offset(x: size.symbolOffset, y: size.fills ? 40 : 24)
            VStack(alignment: .leading, spacing: size.fills ? 6 : 4) {
                Text(pick.kicker).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.85))
                Text(pick.title)
                    .font(size.titleFont)
                    .tracking(size.tracking)
                    .foregroundStyle(.white).lineLimit(2)
                if !pick.subtitle.isEmpty {
                    Text(pick.subtitle)
                        .font(size.fills ? .callout : .caption)
                        .foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text("Play").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
            .padding(size.padding)
        }
        .frame(width: size.fills ? nil : 300, height: size.height)
        .frame(maxWidth: size.fills ? .infinity : nil, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Surface.stroke) }
        .shadow(color: .black.opacity(size.fills ? 0.35 : 0.25), radius: size.fills ? 18 : 10, y: size.fills ? 8 : 4)
    }

    // MARK: Recommendations

    @ViewBuilder private var recommendationsSection: some View {
        if youtube.recommendationsLoading && youtube.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Recommended for you", "Based on your taste")
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
            }
        } else if !youtube.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(eyebrow: "Based on your taste", title: "Recommended for you",
                              accent: Chroma.current) {
                    Button { youtube.loadRecommendations(force: true) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26).contentShape(Circle())
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Refresh")
                }
                .padding(.horizontal, 28)
                LazyVStack(spacing: 3) {
                    ForEach(youtube.recommendations.prefix(12)) { song in
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

    // MARK: Recently played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Recently played", "Lately")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(recents) { e in
                        Button { playEvent(e) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkSquare(image: library.artwork(for: libraryTrack(e)), corner: Radius.row,
                                              remote: eventRemote(e), remoteFallback: eventFallback(e),
                                              seed: libraryTrack(e)?.album)
                                    .frame(width: 118, height: 118)
                                Text(e.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(e.artist.isEmpty ? "Unknown Artist" : e.artist)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 118)
                        }
                        .buttonStyle(PressableCard())
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    // MARK: Most played

    private var mostPlayedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Most played", "Your top tracks")
            LazyVStack(spacing: 2) {
                ForEach(Array(mostPlayed.enumerated()), id: \.element.id) { i, track in
                    Button { player.play(queue: mostPlayed, at: i) } label: {
                        HStack(spacing: 12) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .center)
                            ArtworkSquare(image: library.artwork(for: track), corner: Radius.chip,
                                          remote: track.remoteArtworkURL, remoteFallback: track.remoteArtworkFallbackURL)
                                .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.callout).lineLimit(1)
                                Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(track.playCount ?? 0) play\((track.playCount ?? 0) == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Top artists

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Top artists", "Your artists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(topArtists, id: \.name) { artist in
                        Button { UIState.shared.searchText = artist.name } label: {
                            VStack(spacing: 6) {
                                ArtistAvatar(localArt: artistArt(artist.name),
                                             remote: youtube.artistImage(for: artist.name))
                                    .frame(width: 76, height: 76)
                                    .task(id: youtube.ready) { youtube.loadArtistImage(name: artist.name) }
                                Text(artist.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(artist.plays) play\(artist.plays == 1 ? "" : "s")")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(width: 92)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            EmptyState(icon: "sparkles",
                       title: "Nothing here yet",
                       message: "Play some music and recommendations, history and stats will appear.",
                       framed: true)
                .frame(maxWidth: 420)
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: Helpers

    private func libraryTrack(_ e: PlayEvent) -> Track? { library.tracks.first { $0.path == e.path } }
    private func eventRemote(_ e: PlayEvent) -> URL? {
        if let t = libraryTrack(e) { return t.remoteArtworkURL }
        if let s = e.artworkURL, let u = URL(string: s) { return u }
        if let v = e.videoID { return URL(string: "https://i.ytimg.com/vi/\(v)/mqdefault.jpg") }
        return nil
    }
    private func eventFallback(_ e: PlayEvent) -> URL? {
        e.videoID.map { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg")! }
    }
    private func artistArt(_ name: String) -> NSImage? {
        library.artwork(for: library.tracks.first { $0.artist == name && $0.artworkFile != nil })
    }
    private func playEvent(_ e: PlayEvent) {
        if let t = libraryTrack(e) {
            player.play(queue: [t], at: 0)
        } else if let vid = e.videoID {
            youtube.play(YTResult(id: vid, title: e.title, artist: e.artist, duration: 0,
                                  cover: e.artworkURL.flatMap { URL(string: $0) }))
        }
    }
}

// MARK: - New (new releases from YouTube Music)

struct NewView: View {
    @ObservedObject private var youtube = YouTubeService.shared

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 16, alignment: .top)]

    var body: some View {
        Group {
            if youtube.artistNewLoading && youtube.artistNew.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Finding new music for you…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if youtube.artistNew.isEmpty && youtube.similarNew.isEmpty {
                unavailable
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        featured
                        // Rest of the user's artists' latest releases.
                        section("From artists you listen to", albums: Array(youtube.artistNew.dropFirst(2)))
                        // Discovery that still matches taste: genre-similar artists.
                        section("New for your taste", albums: youtube.similarNew)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 96)
                }
            }
        }
        .task(id: youtube.ready) { youtube.loadArtistNew() }
    }

    @ViewBuilder private func section(_ title: String, albums: [YTAlbum]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.weight(.bold)).padding(.horizontal, 28)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(albums) { YTAlbumCard(album: $0) }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // Two big featured cards — Apple-Music style: kicker + title + artist ABOVE a
    // clean cover. Always taste-based: the freshest releases from the user's own
    // artists, falling back to genre-similar artists.
    @ViewBuilder private var featured: some View {
        let source = youtube.artistNew.isEmpty ? youtube.similarNew : youtube.artistNew
        let top = Array(source.prefix(2))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("New").font(.system(size: 32, weight: .bold)).padding(.horizontal, 28)
                HStack(alignment: .top, spacing: 22) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, album in
                        featureCard(album, kicker: i == 0 ? "NEW RELEASE" : "NEW ALBUM")
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private func featureCard(_ album: YTAlbum, kicker: String) -> some View {
        Button {
            youtube.openAlbum(id: album.id, title: album.title)
            withAnimation(.smooth(duration: 0.3)) { UIState.shared.clearSearch(); UIState.shared.tab = .youtube }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(kicker)
                    .font(.caption.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(album.title).font(.title3.weight(.bold)).foregroundStyle(.primary).lineLimit(1)
                Text(album.artist.isEmpty ? "Album" : album.artist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

                ZStack {
                    RemoteArtwork(url: album.thumb, fallback: album.thumb) { Color(white: 0.15) }
                        .blur(radius: 34).opacity(0.55)
                        .overlay(Color.black.opacity(0.3))
                    ArtworkSquare(image: nil, corner: Radius.row, remote: album.thumb, remoteFallback: album.thumb)
                        .frame(height: 226)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                }
                .frame(maxWidth: .infinity).frame(height: 270)
                .clipShape(RoundedRectangle(cornerRadius: Radius.art))
                .overlay { RoundedRectangle(cornerRadius: Radius.art).strokeBorder(Surface.stroke) }
                .padding(.top, 3)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text("No new music yet").font(.headline)
            Text(!youtube.ready ? "Enable YouTube Music in Settings to see new releases."
                 : Library.shared.tracks.isEmpty ? "Add some music to your library — New is built from the artists you listen to."
                 : "Couldn’t reach YouTube Music right now.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

// MARK: - Profile (identity · stats · collections · preferences · achievements)

/// Round avatar with a gradient-initial fallback.
struct SidebarAvatar: View {
    let image: NSImage?
    var size: CGFloat = 28
    var name: String = ProfileStore.shared.profile.displayName

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.45, green: 0.4, blue: 0.95), Color(red: 0.85, green: 0.3, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Surface.stroke))
    }
    private var initial: String { String(name.first.map(String.init)?.uppercased() ?? "U") }
}

struct ProfileView: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var genres = GenreService.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var youtube = YouTubeService.shared

    @State private var range: StatRange = .month
    @State private var editing = false
    @State private var draftName = ""
    @State private var draftBio = ""

    private var engine: StatsEngine {
        var dur: [String: Double] = [:]
        for t in library.tracks where t.duration > 0 { dur[t.path] = t.duration }
        return StatsEngine(history: library.history, durations: dur)
    }
    private var savedArtists: [String] {
        Array(Set(library.tracks.map(\.artist).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                identityHeader
                statsSection
                collectionsSection
                preferencesSection
                achievementsSection
            }
            .padding(.top, 12)
            .padding(.bottom, 96)
        }
        .tracksContentScroll()
        .task(id: library.history.count) {
            genres.ensure(artists: engine.topArtists(in: .all, limit: 20).map(\.name))
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title3.weight(.bold)).padding(.horizontal, 28)
    }

    // MARK: Identity

    private var identityHeader: some View {
        let p = store.profile
        return HStack(alignment: .top, spacing: 20) {
            Button { store.pickAvatar() } label: {
                ZStack(alignment: .bottomTrailing) {
                    SidebarAvatar(image: store.avatar, size: 96, name: p.displayName)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(Surface.stroke))
                }
            }
            .buttonStyle(.plain).help("Change photo")

            VStack(alignment: .leading, spacing: 8) {
                if editing {
                    TextField("Display name", text: $draftName)
                        .textFieldStyle(.plain).font(.system(size: 30, weight: .heavy))
                    TextField("Add a bio — e.g. “Jazz lover · vinyl collector”", text: $draftBio, axis: .vertical)
                        .textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary).lineLimit(1...3)
                } else {
                    Text(p.displayName).font(.system(size: 34, weight: .heavy)).lineLimit(1)
                    if p.bio.isEmpty {
                        Text("No bio yet").font(.callout).foregroundStyle(.tertiary)
                    } else {
                        Text(p.bio).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                HStack(spacing: 14) {
                    Label("Joined \(p.joinDate.formatted(.dateTime.month(.abbreviated).year()))",
                          systemImage: "calendar").font(.caption).foregroundStyle(.tertiary)
                    Label(p.isPrivate ? "Private" : "Public",
                          systemImage: p.isPrivate ? "lock.fill" : "globe").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)

                HStack(spacing: 10) {
                    if editing {
                        Button("Save") {
                            store.profile.displayName = draftName.trimmingCharacters(in: .whitespaces).isEmpty ? store.profile.displayName : draftName
                            store.profile.bio = draftBio
                            editing = false
                        }.buttonStyle(.glassProminent)
                        Button("Cancel") { editing = false }.buttonStyle(.glass)
                    } else {
                        Button { draftName = p.displayName; draftBio = p.bio; editing = true } label: {
                            Label("Edit Profile", systemImage: "pencil")
                        }.buttonStyle(.glass)
                        Toggle(isOn: Binding(get: { store.profile.isPrivate },
                                             set: { store.profile.isPrivate = $0 })) {
                            Text("Private").font(.caption.weight(.semibold))
                        }
                        .toggleStyle(.switch).controlSize(.mini)
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    // MARK: Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Listening Stats").font(.title3.weight(.bold))
                Spacer()
                Picker("", selection: $range) {
                    ForEach(StatRange.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 280).labelsHidden()
            }
            .padding(.horizontal, 28)

            // headline numbers
            HStack(spacing: 14) {
                statTile(value: timeString(engine.totalSeconds(in: range)), label: "Listening time", symbol: "clock.fill",
                         colors: [Color(red: 0.2, green: 0.5, blue: 0.95), Color(red: 0.35, green: 0.3, blue: 0.85)])
                statTile(value: "\(engine.totalPlays(in: range))", label: "Tracks played", symbol: "music.note",
                         colors: [Color(red: 0.95, green: 0.45, blue: 0.25), Color(red: 0.9, green: 0.25, blue: 0.45)])
                statTile(value: "\(engine.streak())", label: "Day streak", symbol: "flame.fill",
                         colors: [Color(red: 0.95, green: 0.6, blue: 0.15), Color(red: 0.9, green: 0.35, blue: 0.2)])
            }
            .padding(.horizontal, 28)

            HStack(alignment: .top, spacing: 22) {
                topArtistsColumn
                topTracksColumn
            }
            .padding(.horizontal, 28)

            topGenresView
        }
    }

    private func statTile(value: String, label: String, symbol: String, colors: [Color]) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol).font(.system(size: 64, weight: .bold))
                .foregroundStyle(Surface.active).offset(x: 90, y: 14)
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: symbol).font(.callout).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(value).font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
        }
        .frame(height: 104).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
    }

    private var topArtistsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Artists").font(.headline)
            let items = engine.topArtists(in: range, limit: 5)
            if items.isEmpty { Text("No plays yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16)
                    ArtistAvatar(localArt: artistArt(a.name), remote: youtube.artistImage(for: a.name))
                        .frame(width: 34, height: 34)
                    Text(a.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(a.plays)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topTracksColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Tracks").font(.headline)
            let items = engine.topTracks(in: range, limit: 5)
            if items.isEmpty { Text("No plays yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16)
                    ArtworkSquare(image: trackArt(t.id), corner: Radius.chip,
                                  remote: t.videoID.map { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg")! } ?? t.artworkURL.flatMap { URL(string: $0) },
                                  remoteFallback: t.videoID.map { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg")! })
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.callout).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(t.plays)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var topGenresView: some View {
        let bd = genres.breakdown(weightedBy: engine.topArtists(in: range, limit: 20))
        if !bd.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Genres").font(.headline)
                ForEach(Array(bd.prefix(5)), id: \.genre) { g in
                    HStack(spacing: 10) {
                        Text(g.genre).font(.caption.weight(.medium)).frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Surface.base)
                                Capsule().fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                                              startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * g.fraction))
                            }
                        }
                        .frame(height: 10)
                        Text("\(Int((g.fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your Library")
            HStack(spacing: 14) {
                collectionCard("Liked Songs", count: library.favorites.count, symbol: "heart.fill",
                               colors: [Color(red: 0.9, green: 0.2, blue: 0.4), Color(red: 0.7, green: 0.15, blue: 0.5)]) { ui(.playlists) }
                collectionCard("Playlists", count: library.playlists.count, symbol: "music.note.list",
                               colors: [Color(red: 0.25, green: 0.55, blue: 0.5), Color(red: 0.15, green: 0.35, blue: 0.45)]) { ui(.playlists) }
                collectionCard("Albums", count: library.albums.count, symbol: "square.stack.fill",
                               colors: [Color(red: 0.45, green: 0.35, blue: 0.85), Color(red: 0.3, green: 0.3, blue: 0.7)]) { ui(.albums) }
                collectionCard("Artists", count: savedArtists.count, symbol: "music.mic",
                               colors: [Color(red: 0.55, green: 0.45, blue: 0.2), Color(red: 0.4, green: 0.3, blue: 0.2)]) { ui(.artists) }
            }
            .padding(.horizontal, 28)
        }
    }

    private func collectionCard(_ title: String, count: Int, symbol: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.system(size: 50, weight: .bold)).foregroundStyle(Surface.active).offset(x: 60, y: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: symbol).font(.callout).foregroundStyle(.white)
                    Spacer()
                    Text("\(count)").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white)
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }.padding(12)
            }
            .frame(height: 96).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        }
        .buttonStyle(.plain)
    }

    // MARK: Preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Preferences")
            VStack(alignment: .leading, spacing: 14) {
                Text("Preferred genres — used to tune your Home recommendations")
                    .font(.caption).foregroundStyle(.secondary)
                FlowChips(items: GenreService.allGenres,
                          selected: store.profile.preferredGenres) { g in
                    if let i = store.profile.preferredGenres.firstIndex(of: g) {
                        store.profile.preferredGenres.remove(at: i)
                    } else {
                        store.profile.preferredGenres.append(g)
                    }
                }
                Divider().opacity(0.15)
                Toggle(isOn: Binding(get: { store.profile.explicitFilter },
                                     set: { store.profile.explicitFilter = $0 })) {
                    Label("Filter explicit content", systemImage: "e.square.fill")
                }
                HStack {
                    Label("Audio quality & theme live in Settings", systemImage: "slider.horizontal.3")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
            .padding(18)
            .background(Surface.quiet, in: RoundedRectangle(cornerRadius: Radius.panel))
            .padding(.horizontal, 28)
        }
    }

    // MARK: Achievements

    private var achievementsSection: some View {
        let plays = engine.totalPlays(in: .all)
        let minutes = Int(engine.totalSeconds(in: .all) / 60)
        let lvl = Gamification.level(plays: plays, minutes: minutes)
        let badges = Gamification.badges(plays: plays, genres: genres.distinctGenreCount,
                                         streak: engine.streak(), nightOwl: engine.nightOwlPlays(),
                                         minutes: minutes, favorites: library.favorites.count)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Achievements")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Level \(lvl.level)").font(.title3.weight(.heavy))
                    Spacer()
                    Text("\(lvl.intoLevel) / \(lvl.span) XP").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Surface.base)
                        Capsule().fill(LinearGradient(colors: [Color(red: 0.95, green: 0.6, blue: 0.15), Color(red: 0.9, green: 0.3, blue: 0.5)],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * lvl.fraction))
                    }
                }.frame(height: 12)
            }
            .padding(18)
            .background(Surface.quiet, in: RoundedRectangle(cornerRadius: Radius.panel))
            .padding(.horizontal, 28)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(badges) { badge in
                    HStack(spacing: 10) {
                        Image(systemName: badge.symbol)
                            .font(.title3)
                            .foregroundStyle(badge.earned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .frame(width: 38, height: 38)
                            .background(badge.earned ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Surface.quiet), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(badge.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(badge.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Surface.quiet, in: RoundedRectangle(cornerRadius: Radius.art))
                    .opacity(badge.earned ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: Helpers

    private func ui(_ tab: Tab) { withAnimation(.smooth(duration: 0.25)) { UIState.shared.tab = tab } }
    private func trackArt(_ path: String) -> NSImage? { library.artwork(for: library.tracks.first { $0.path == path }) }
    private func artistArt(_ name: String) -> NSImage? {
        library.artwork(for: library.tracks.first { $0.artist == name && $0.artworkFile != nil })
    }
    private func timeString(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }
}

/// Wrapping selectable chips (for preferred genres).
struct FlowChips: View {
    let items: [String]
    let selected: [String]
    let toggle: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = selected.contains(item)
                Button { toggle(item) } label: {
                    Text(item).font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Surface.base),
                                    in: Capsule())
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
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

    /// Trivia/lyrics features apply to tracks that came from the app (streamed
    /// or downloaded from YouTube), not the user's own imported files.
    private func isAppTrack(_ t: Track) -> Bool {
        t.youtubeVideoID != nil || t.path.contains("/Mute/YouTube/")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            playerColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if player.current != nil, !ui.npSidebarHidden {
                sidePanel
                    .frame(width: 290)
                    .padding(.trailing, 24)
                    .padding(.vertical, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if player.current != nil, ui.npSidebarHidden {
                Button { withAnimation(.smooth(duration: 0.3)) { ui.npSidebarHidden = false } } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .padding(.trailing, 22).padding(.top, 20)
                .help("Show Up Next")
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
            if let track = player.current, isAppTrack(track) {
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
                // A real cover's dominant colour first; for an artless track
                // fall back to its placeholder hue rather than black, which
                // would mean no glow at all.
                let glowSource = library.dominantColor(for: track)
                    ?? Placeholder.tint(seed: track.album)
                let glow = glowSource.map { Color(nsColor: $0) } ?? .black
                VStack(spacing: 26) {
                    ArtworkCard(artwork: library.artwork(for: track),
                                remote: track.remoteArtworkURL,
                                remoteFallback: track.remoteArtworkFallbackURL,
                                seed: track.album)
                        .frame(width: 300, height: 300)
                        // Breathe with playback (Apple Music shrinks paused art),
                        // and cast a soft ambient glow in the artwork's own color.
                        .scaleEffect(ui.artZoom * (player.isPlaying ? 1.0 : 0.86))
                        .shadow(color: glow.opacity(player.isPlaying ? 0.5 : 0),
                                radius: 46, y: 18)
                        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
                        .animation(.smooth(duration: 0.25), value: ui.artZoom)
                        .animation(.smooth(duration: 0.5), value: glow)
                        .id(track.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity.combined(with: .scale(scale: 1.04))))
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
                                    .background(Surface.active, in: .capsule)
                                    .help("Device sample rate matched to the file — untouched signal path")
                            }
                            let liked = library.isFavorite(path: track.path)
                            Button { library.toggleLike(track) } label: {
                                Image(systemName: liked ? "heart.fill" : "heart")
                                    .font(.system(size: 15))
                                    .foregroundStyle(liked ? .pink : .secondary)
                                    .contentShape(Rectangle())
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .help(liked ? "Remove from Liked Music" : "Add to Liked Music")
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
                .appGlass(in: .rect(cornerRadius: Radius.sheet))
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .animation(.smooth(duration: 0.4), value: player.current?.id)
    }

    // MARK: Up Next + Song Trivia side panel

    private var upcoming: [(Int, Track)] {
        guard let ci = player.currentIndex else { return [] }
        return player.tracks.enumerated().filter { $0.offset > ci }.map { ($0.offset, $0.element) }
    }

    private var sidePanel: some View {
        VStack(spacing: 14) {
            upNextCard
            if let track = player.current, isAppTrack(track) {
                triviaCard
            }
        }
    }

    private var upNextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
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
                Button { withAnimation(.smooth(duration: 0.3)) { ui.npSidebarHidden = true } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .foregroundStyle(.secondary)
                .help("Hide panel")
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
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.panel))
        .appGlass(in: .rect(cornerRadius: Radius.panel))
    }

    private func upNextRow(_ track: Track, index: Int) -> some View {
        Button { player.play(at: index) } label: {
            HStack(spacing: 10) {
                ArtworkSquare(image: library.artwork(for: track), corner: Radius.chip,
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
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.panel))
        .appGlass(in: .rect(cornerRadius: Radius.panel))
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
                Button { withAnimation(.smooth(duration: 0.3)) { ui.lyricsOpen.toggle() } } label: {
                    Image(systemName: "quote.bubble")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ui.lyricsOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .help("Lyrics")
                .padding(.leading, 6)
                Button { MiniPlayerController.shared.toggle() } label: {
                    Image(systemName: "pip")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Mini player (.)")
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

/// Full-screen Apple-Music-style lyrics: large synced lines that scroll and
/// highlight with playback; tap a line to seek. Opened from the playing bar.
struct LyricsFullView: View {
    @ObservedObject private var youtube = YouTubeService.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var clock = PlaybackClock.shared
    @ObservedObject private var ui = UIState.shared

    private var lines: [LyricLine] { youtube.lyrics?.lines ?? [] }
    private var currentIndex: Int {
        let t = clock.elapsed + 0.25
        var idx = 0
        for (i, l) in lines.enumerated() { if l.time <= t { idx = i } else { break } }
        return idx
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            backdrop.opacity(0.45)
            Color.black.opacity(0.35)

            VStack(spacing: 0) {
                header
                content
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task(id: player.current?.id) {
            if let track = player.current { youtube.loadLyrics(for: track) }
        }
    }

    private var backdrop: some View {
        Color.clear.overlay {
            if let art = library.artwork(for: player.current) {
                Image(nsImage: art).resizable().scaledToFill()
            } else if let url = player.current?.remoteArtworkURL {
                RemoteArtwork(url: url, fallback: player.current?.remoteArtworkFallbackURL) { Color.clear }
            }
        }
        .clipped()
        .blur(radius: 90)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "")
                    .font(.system(size: 26, weight: .heavy)).lineLimit(2)
                Text(player.current?.artist.isEmpty == false ? player.current!.artist : "Unknown Artist")
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { withAnimation(.smooth(duration: 0.3)) { ui.lyricsOpen = false } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36).contentShape(Circle())
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .help("Close lyrics")
        }
        .padding(.horizontal, 44).padding(.top, 56).padding(.bottom, 18)
    }

    @ViewBuilder private var content: some View {
        if youtube.lyricsLoading {
            Spacer(); ProgressView().controlSize(.large); Spacer()
        } else if let ly = youtube.lyrics, ly.synced {
            syncedLyrics(ly)
        } else if let ly = youtube.lyrics, !ly.plain.isEmpty {
            ScrollView {
                Text(ly.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 44).padding(.vertical, 30)
            }
        } else {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "quote.bubble").font(.system(size: 38)).foregroundStyle(.secondary)
                Text("No lyrics available for this track.").font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func syncedLyrics(_ ly: Lyrics) -> some View {
        let cur = min(currentIndex, ly.lines.count - 1)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(ly.lines.enumerated()), id: \.element.id) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(i == cur ? Color.primary : Color.secondary.opacity(0.4))
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let dur = player.currentDuration
                                if dur > 0 { player.seek(to: line.time / dur) }
                            }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44).padding(.top, 20).padding(.bottom, 160)
            }
            .onChange(of: cur) { _, idx in
                withAnimation(.smooth(duration: 0.45)) {
                    proxy.scrollTo(ly.lines[min(idx, ly.lines.count - 1)].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ui = UIState.shared
    @State private var editingAlbum: Album?
    /// Ties each grid cover to the same cover in the detail header, so opening
    /// an album flies the artwork into place instead of cutting to a new screen.
    @Namespace private var albumNS

    var body: some View {
        Group {
            if let id = ui.albumSelection, let album = library.albums.first(where: { $0.id == id }) {
                AlbumDetailView(album: album,
                                back: { withAnimation(Motion.navigate) { ui.albumSelection = nil } },
                                edit: { editingAlbum = album },
                                namespace: albumNS)
                    // Plain fade: the cover carries the movement, and a sliding
                    // panel underneath it would pull in the opposite direction.
                    .transition(.opacity)
            } else if library.tracks.isEmpty {
                VStack {
                    Spacer()
                    EmptyState(icon: "music.note",
                               title: "Drop music here",
                               message: "or press + to add files or folders",
                               framed: true)
                        .fixedSize()
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
                                          edit: { editingAlbum = album },
                                          namespace: albumNS)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 96)
                    }
                    .tracksContentScroll()
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
            withAnimation(Motion.navigate) { ui.albumSelection = album.id }
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
            PlayButton(kind: .prominent) { Player.shared.play(queue: selectedTracks, at: 0) }
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
    /// Supplied only where the card can open into a detail screen.
    var namespace: Namespace.ID? = nil
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared

    /// True while anything from this album is the current track.
    private var isCurrent: Bool {
        guard let current = player.current else { return false }
        return album.tracks.contains { $0.id == current.id }
    }

    /// `Album.artist` is synthesized as "Unknown Artist" when nothing on the
    /// album is tagged — the track count tells you more than that does.
    private var subtitle: String {
        guard album.artist == "Unknown Artist" else { return album.artist }
        return "\(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")"
    }

    var body: some View {
        CoverCard(title: album.name,
                  subtitle: subtitle,
                  onPlay: { Player.shared.play(queue: album.tracks, at: 0) },
                  open: open) {
            ArtworkSquare(image: library.artwork(for: album), corner: Radius.art,
                          remote: album.remoteArtworkURL,
                          remoteFallback: album.remoteArtworkFallbackURL,
                          seed: album.name)
                .matchedIfPresent("album-\(album.id)", in: namespace)
        } accessory: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.art)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2.5)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.black, .white)
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.scale.combined(with: .opacity))
                }
                if isCurrent && !selected {
                    // Same speaker idiom the track rows use, so "this is the one
                    // playing" looks the same everywhere.
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: Circle())
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .opacity(selected ? 0.92 : 1)
        .animation(Motion.hover, value: isCurrent)
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
    var namespace: Namespace.ID? = nil
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @State private var artistHover = false

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
            ArtworkSquare(image: library.artwork(for: album), corner: Radius.art,
                          remote: album.remoteArtworkURL,
                          remoteFallback: album.remoteArtworkFallbackURL,
                          seed: album.name)
                .frame(width: 130, height: 130)
                .matchedIfPresent("album-\(album.id)", in: namespace)
            VStack(alignment: .leading, spacing: 6) {
                MetaLine(text: "Album")
                Text(album.name)
                    .font(TypeScale.section)
                    .tracking(-0.6)
                    .lineLimit(2)
                Button {
                    let name = album.artist
                    guard !name.isEmpty, name != "Unknown Artist", name != "Various Artists" else { return }
                    UIState.shared.clearSearch()
                    withAnimation(.smooth(duration: 0.25)) {
                        UIState.shared.artistSelection = name
                        UIState.shared.tab = .artists
                    }
                } label: {
                    Text(album.artist)
                        .font(.callout)
                        .foregroundStyle(artistHover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .underline(artistHover)
                }
                .buttonStyle(.plain)
                .onHover { artistHover = $0 }
                .help("Go to \(album.artist)")
                HStack(spacing: 14) {
                    MetaLine(text: "\(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s") · \(Int(album.tracks.reduce(0) { $0 + $1.duration } / 60)) min")
                        .fixedSize()
                    PlayButton(kind: .prominent) {
                        Player.shared.play(queue: album.tracks, at: 0)
                    }
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
                    ArtworkSquare(image: newArtwork ?? library.artwork(for: album), corner: Radius.art,
                                  remote: album.remoteArtworkURL,
                                  remoteFallback: album.remoteArtworkFallbackURL,
                                  seed: album.name)
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
    @ObservedObject private var library = Library.shared
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
            MetaLine(text: "Mute")
            Text("Settings")
                .font(TypeScale.page)
                .tracking(-0.4)
                .padding(.bottom, 12)
            ForEach(SettingsCategory.allCases) { cat in
                Button { category = cat } label: {
                    HStack(spacing: 10) {
                        Image(systemName: cat.icon).font(.system(size: 13)).frame(width: 18)
                        Text(cat.label).font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background {
                        // Same pill as the main sidebar, same accent.
                        if category == cat {
                            RoundedRectangle(cornerRadius: Radius.chip)
                                .fill(Chroma.current.opacity(0.24))
                                .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                                    .strokeBorder(Chroma.current.opacity(0.40), lineWidth: 1))
                        }
                    }
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
        Text(title).font(TypeScale.section).tracking(-0.6)
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
                Button { watcher.sweep() } label: {
                    Label(library.importing ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(library.importing)
                .help("Look through these folders and your downloads for music that isn't in the library yet")
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
            // Always scanned, never removable — show it so downloaded music
            // doesn't look like it appeared from nowhere.
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                Text((YouTubeService.downloadDir.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Always").font(.caption2).foregroundStyle(.tertiary)
            }
            caption(watcher.folders.isEmpty
                    ? "New audio files in watched folders (e.g. your DAW bounces) are imported automatically. Your downloads folder is always scanned at launch."
                    : "Your downloads folder is always scanned at launch, so downloaded music can't go missing from the library.")
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
                            .background(ui.searchScope == scope ? AnyShapeStyle(Surface.active)
                                                                : AnyShapeStyle(Surface.quiet),
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
            case .artist:
                // YTArtistView has its own hero with an overlaid back button.
                YTArtistView()
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
                                Button {
                                    // Open the full artist page (not a re-search) so the
                                    // album-artist isn't split off from the artist itself.
                                    ui.clearSearch()
                                    withAnimation(.smooth(duration: 0.25)) {
                                        ui.artistSelection = artist.name
                                        ui.tab = .artists
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        ArtistAvatar(localArt: artist.art, remote: youtube.artistImage(for: artist.name))
                                            .frame(width: 60, height: 60)
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
                .background(Surface.active, in: .capsule)
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
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Search artists, albums and songs", text: $youtube.query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onSubmit { youtube.search() }
                if youtube.searching {
                    ProgressView().controlSize(.small)
                } else if !youtube.query.isEmpty {
                    Button { youtube.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .appGlass(in: .capsule)

            HStack(spacing: 6) {
                Label(youtube.online ? "Online" : "Offline",
                      systemImage: youtube.online ? "wifi" : "wifi.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(youtube.online ? .green : .orange)
                Spacer()
                Text("Tap to stream · download to replay offline")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
                .appGlass(in: .rect(cornerRadius: Radius.art))
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
        .tracksContentScroll()
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
                    VStack(alignment: .leading, spacing: 22) {
                        hero(detail)
                        if !detail.bio.isEmpty {
                            ArtistBio(text: detail.bio).padding(.horizontal, 28)
                        }
                        if !detail.topSongs.isEmpty {
                            YTSectionHeader(title: "Top Songs", count: detail.topSongs.count)
                            LazyVStack(spacing: 3) {
                                ForEach(detail.topSongs.prefix(8)) { song in
                                    YTResultRow(result: song,
                                                onPlay: { youtube.play(song) },
                                                onDownload: { youtube.download(song) },
                                                onAdd: { youtube.addToLibrary(song) })
                                }
                            }
                            .padding(.horizontal, 20)
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
                    .padding(.bottom, 96)
                }
            } else {
                YTNote(text: "Couldn’t load this artist.", icon: "exclamationmark.triangle")
            }
        }
    }

    private func hero(_ detail: YTArtistDetail) -> some View {
        let height: CGFloat = 300
        return ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(maxWidth: .infinity).frame(height: height)
                .overlay {
                    RemoteArtwork(url: ArtistsView.widen(detail.thumb), fallback: detail.thumb) {
                        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
                .overlay(
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.35), location: 0.0),
                        .init(color: .clear, location: 0.4),
                        .init(color: .clear, location: 0.5),
                        .init(color: .black.opacity(0.6), location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .mask(
                    LinearGradient(stops: [
                        .init(color: Surface.quiet, location: 0.0),
                        .init(color: .white, location: 0.16),
                        .init(color: .white, location: 0.72),
                        .init(color: Surface.quiet, location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                )
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ARTIST").font(.caption2.weight(.bold)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(detail.name).font(.system(size: 42, weight: .heavy))
                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                    if !detail.subscribers.isEmpty {
                        Text("\(detail.subscribers) subscribers")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                    }
                }
                Spacer()
                PlayButton(kind: .prominent) { if let first = detail.topSongs.first { youtube.play(first) } }
                    .disabled(detail.topSongs.isEmpty || !youtube.online)
            }
            .padding(24)
        }
        .frame(height: height).frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            BackButton { youtube.back() }.padding(16)
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
            YTArt(url: detail.thumb, size: 150, corner: Radius.art, placeholder: "opticaldisc")
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
                PlayButton(kind: .prominent) { youtube.playAlbum(detail) }
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

    private var subtitle: String {
        album.year.isEmpty ? album.kind : "\(album.kind) · \(album.year)"
    }

    var body: some View {
        CoverCard(width: 132, title: album.title, subtitle: subtitle, open: {
            YouTubeService.shared.openAlbum(id: album.id, title: album.title)
            withAnimation(Motion.navigate) { UIState.shared.clearSearch(); UIState.shared.tab = .youtube }
        }) {
            YTArt(url: album.thumb, size: 132, corner: Radius.art, placeholder: "opticaldisc")
        }
    }
}

/// Circular artist avatar; tapping opens the artist profile.
struct YTArtistCircle: View {
    let artist: YTArtist

    var body: some View {
        Button {
            YouTubeService.shared.openArtist(id: artist.id, name: artist.name)
            withAnimation(.smooth(duration: 0.3)) { UIState.shared.clearSearch(); UIState.shared.tab = .youtube }
        } label: {
            VStack(spacing: 7) {
                YTArt(url: artist.thumb, size: 78, corner: 39, placeholder: "person.fill")
                Text(artist.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 92)
            }
        }
        .buttonStyle(PressableCard())
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
            Rectangle().fill(Surface.base)
                .overlay(Image(systemName: placeholder).font(.title3).foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Surface.stroke) }
    }
}

/// The YouTube screens used to carry their own header style. They use the same
/// one as the rest of the app now; only the trailing count is theirs.
struct YTSectionHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        SectionHeader(title: title, accent: Chroma.current) {
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Surface.stroke, in: .capsule)
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
                    .frame(width: 24, alignment: .center)
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
        .mediaRow(onTap: onPlay) { hovered = $0 }
    }

    private var thumbnail: some View {
        AsyncImage(url: result.thumbnailURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Surface.base)
                .overlay(Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary))
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Surface.stroke) }
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
            Circle().stroke(Surface.stroke, lineWidth: 2.5)
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
            Circle().stroke(Surface.stroke, lineWidth: 5)
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
            ArtworkSquare(image: library.artwork(for: track), corner: Radius.row,
                          remote: track.remoteArtworkURL,
                          remoteFallback: track.remoteArtworkFallbackURL,
                          seed: track.album)
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
                .padding(.top, 6)
                .padding(.bottom, 14)

                if library.playlists.isEmpty && library.favorites.isEmpty {
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
                        .appGlass(in: .rect(cornerRadius: Radius.sheet))
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], spacing: 22) {
                            if !library.favorites.isEmpty {
                                FavoritesCard(count: library.favorites.count) { showFavorites = true }
                            }
                            ForEach(library.playlists) { playlist in
                                PlaylistCard(playlist: playlist) { ui.playlistSelection = playlist.id }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                        .padding(.bottom, 96)
                    }
                    .tracksContentScroll()
                }
            }
        }
    }
}

/// Album-grid-style playlist card: a 2×2 cover collage of its tracks, name and
/// song count below — matching the Albums/Artists views.
struct PlaylistCard: View {
    let playlist: Playlist
    let open: () -> Void
    @ObservedObject private var library = Library.shared

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                PlaylistCover(tracks: library.tracks(for: playlist))
                Text(playlist.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(playlist.trackIDs.count) song\(playlist.trackIDs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PressableCard())
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

/// A playlist cover: a 2×2 collage of up to four distinct track covers (local
/// or remote), a single cover for short playlists, or a gradient when empty.
struct PlaylistCover: View {
    let tracks: [Track]
    @ObservedObject private var library = Library.shared

    private var picks: [Track] {
        var seen = Set<String>(); var out: [Track] = []
        for t in tracks {
            let key = t.artworkFile ?? t.artworkURL ?? t.albumKey ?? t.id.uuidString
            if seen.insert(key).inserted { out.append(t) }
            if out.count == 4 { break }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                if picks.isEmpty {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note.list")
                        .font(.system(size: s * 0.26, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                } else if picks.count >= 4 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { tile(picks[0], s / 2); tile(picks[1], s / 2) }
                        HStack(spacing: 0) { tile(picks[2], s / 2); tile(picks[3], s / 2) }
                    }
                } else {
                    tile(picks[0], s)
                }
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.art))
        .overlay(RoundedRectangle(cornerRadius: Radius.art).strokeBorder(Surface.stroke))
    }

    private func tile(_ t: Track, _ size: CGFloat) -> some View {
        ArtworkSquare(image: library.artwork(for: t), corner: 0,
                      remote: t.remoteArtworkURL, remoteFallback: t.remoteArtworkFallbackURL)
            .frame(width: size, height: size)
    }
}

/// The Favourites entry, styled as a card to match the playlist grid.
struct FavoritesCard: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [Color(.sRGB, red: 0.95, green: 0.30, blue: 0.45),
                                            Color(.sRGB, red: 0.55, green: 0.10, blue: 0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.art))
                .overlay(RoundedRectangle(cornerRadius: Radius.art).strokeBorder(Surface.stroke))
                Text("Favourites")
                    .font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text("\(count) song\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PressableCard())
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

    @FocusState private var nameFocused: Bool
    @State private var showAddSongs = false

    var body: some View {
        let live = library.playlists.first(where: { $0.id == playlist.id }) ?? playlist
        let tracks = library.tracks(for: live)
        VStack(alignment: .leading, spacing: 0) {
            BackButton(action: back)
                .padding(.horizontal, 28).padding(.top, 16)
            header(tracks)
                .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 14)

            if tracks.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text("This playlist is empty")
                            .font(.headline)
                        Button { showAddSongs = true } label: {
                            Label("Add Songs", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.vertical, 44).padding(.horizontal, 56)
                    .appGlass(in: .rect(cornerRadius: Radius.sheet))
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
                                Divider()
                                Button("Move Up") { library.movePlaylistTrack(live.id, trackID: track.id, by: -1) }
                                    .disabled(index == 0)
                                Button("Move Down") { library.movePlaylistTrack(live.id, trackID: track.id, by: 1) }
                                    .disabled(index == tracks.count - 1)
                                Button("Remove from Playlist", role: .destructive) {
                                    library.removeFromPlaylist(live.id, trackID: track.id)
                                }
                                Divider()
                                Button("Get Info…") { UIState.shared.infoTrack = track }
                                AddToPlaylistMenu(trackIDs: [track.id])
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 96)
                }
            }
        }
        .onDisappear { library.renamePlaylist(playlist.id, to: name) }
        .sheet(isPresented: $showAddSongs) { AddSongsSheet(playlistID: playlist.id) }
    }

    private func header(_ tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            PlaylistCover(tracks: tracks)
                .frame(width: 132, height: 132)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Playlist name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.bold))
                        .focused($nameFocused)
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(nameFocused ? AnyShapeStyle(Surface.base) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: Radius.chip))
                        .onSubmit { library.renamePlaylist(playlist.id, to: name); nameFocused = false }
                    Button { nameFocused = true } label: {
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Rename playlist")
                }
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(Int(tracks.reduce(0) { $0 + $1.duration } / 60)) min")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    PlayButton(kind: .prominent) { if !tracks.isEmpty { player.play(queue: tracks, at: 0) } }
                        .disabled(tracks.isEmpty)
                    Button { if !tracks.isEmpty { player.play(queue: tracks.shuffled(), at: 0) } } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.glass).disabled(tracks.isEmpty)
                    Button { showAddSongs = true } label: {
                        Label("Add Songs", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    Menu {
                        Button("Rename") { nameFocused = true }
                        Button("Delete Playlist", role: .destructive) {
                            library.deletePlaylist(playlist.id); back()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 30).contentShape(Circle())
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).menuIndicator(.hidden)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Sheet for adding songs to a playlist — from the library or from YouTube
/// search (YouTube hits are imported as streaming tracks, then added).
struct AddSongsSheet: View {
    let playlistID: UUID
    @ObservedObject private var library = Library.shared
    @ObservedObject private var youtube = YouTubeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var ytResults: [YTResult] = []
    @State private var ytSearching = false
    @State private var searchTask: Task<Void, Never>?

    /// Track paths already in the playlist (for the added ✓ state).
    private var playlistPaths: Set<String> {
        let ids = Set(library.playlists.first(where: { $0.id == playlistID })?.trackIDs ?? [])
        return Set(library.tracks.filter { ids.contains($0.id) }.map(\.path))
    }
    private var libraryResults: [Track] {
        let all = library.tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let paths = playlistPaths
        VStack(spacing: 0) {
            HStack {
                Text("Add Songs").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search your library and YouTube", text: $query).textFieldStyle(.plain)
                if ytSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .appGlass(in: .capsule)
            .padding(.horizontal, 16).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !libraryResults.isEmpty {
                        sectionLabel("Your Library")
                        ForEach(libraryResults) { track in
                            row(title: track.title, artist: track.artist,
                                image: library.artwork(for: track),
                                remote: track.remoteArtworkURL, fallback: track.remoteArtworkFallbackURL,
                                added: paths.contains(track.path)) {
                                library.add(trackIDs: [track.id], to: playlistID)
                            }
                        }
                    }
                    if !query.isEmpty {
                        sectionLabel("From YouTube")
                        if ytResults.isEmpty && !ytSearching {
                            Text(youtube.ready ? "No YouTube results." : "YouTube isn’t set up.")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        ForEach(ytResults) { result in
                            row(title: result.title, artist: result.artist,
                                image: nil, remote: result.thumbnailURL, fallback: nil,
                                added: paths.contains("ytmusic://\(result.id)")) {
                                youtube.addToPlaylist(result, playlist: playlistID)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(width: 460, height: 560)
        .preferredColorScheme(.dark)
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { ytResults = []; ytSearching = false; return }
            ytSearching = true
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                let r = await youtube.searchSongs(trimmed)
                guard !Task.isCancelled else { return }
                ytResults = r
                ytSearching = false
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }

    private func row(title: String, artist: String, image: NSImage?, remote: URL?, fallback: URL?,
                     added: Bool, add: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ArtworkSquare(image: image, corner: Radius.chip, remote: remote, remoteFallback: fallback)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1)
                Text(artist.isEmpty ? "Unknown Artist" : artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: add) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3).foregroundStyle(added ? .green : .secondary)
            }
            .buttonStyle(.plain).disabled(added)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FavoritesDetailView: View {
    let back: () -> Void
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        let tracks = library.favorites
        VStack(alignment: .leading, spacing: 0) {
            BackButton(action: back)
                .padding(.horizontal, 28).padding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                Label("Favourites", systemImage: "heart.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary, .pink)
                HStack(spacing: 14) {
                    Text("\(tracks.count) songs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    PlayButton(kind: .prominent) {
                        if !tracks.isEmpty { player.play(queue: tracks, at: 0) }
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
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
        .mediaRow(isCurrent: isCurrent, pressable: false, onTap: play) { hovered = $0 }
        .onDrag { NSItemProvider(object: track.id.uuidString as NSString) }
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
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "speaker.fill") : "music.note")
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 24)
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
        .mediaRow(isCurrent: isCurrent, onTap: play) { hovered = $0 }
    }
}

struct MiniBar: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 7) {
                HStack(spacing: 11) {
                    ArtworkSquare(image: library.artwork(for: player.current), corner: Radius.row,
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
                                .background(Surface.active, in: .circle)
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

                    Divider().frame(height: 20).opacity(0.25)

                    Button { withAnimation(.smooth(duration: 0.3)) { ui.lyricsOpen.toggle() } } label: {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ui.lyricsOpen ? Color.accentColor : .secondary)
                    .help("Lyrics")

                    Button { withAnimation(.smooth(duration: 0.3)) { ui.tab = .nowPlaying } } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Up Next")
                }
                MiniProgress()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .frame(width: 470)
            .appGlass(in: .rect(cornerRadius: Radius.sheet), interactive: true)
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
                Capsule().fill(Surface.active)
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
        .animation(Motion.hover, value: hovered)
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
    var corner: CGFloat = Radius.art
    /// Remote cover (and fallback) used when there's no local `image`.
    var remote: URL? = nil
    var remoteFallback: URL? = nil
    /// Tints the artless placeholder from this string (an album or track name),
    /// so a library of untagged files reads as distinct covers instead of a
    /// wall of identical grey squares. Nil keeps the neutral grey.
    var seed: String? = nil

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
                    .strokeBorder(Surface.stroke, lineWidth: 1)
            )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: placeholderColors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var placeholderColors: [Color] { Placeholder.colors(seed: seed) }
}

struct ArtworkCard: View {
    let artwork: NSImage?
    /// Remote cover (and fallback) used when there's no local `artwork`.
    var remote: URL? = nil
    var remoteFallback: URL? = nil
    /// Tints the artless placeholder — see `ArtworkSquare.seed`.
    var seed: String? = nil

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
            .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sheet)
                    .strokeBorder(Surface.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: Placeholder.colors(seed: seed),
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
                Capsule().fill(Surface.active)
                Capsule()
                    .fill(Chroma.current)
                    .frame(width: max(hovered ? 7 : 5, geo.size.width * fraction))
                    .shadow(color: Chroma.current.opacity(hovered ? 0.55 : 0), radius: hovered ? 6 : 0)
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
        .animation(Motion.hover, value: hovered)
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
        let source = library.dominantColor(for: player.current)
            ?? Placeholder.tint(seed: player.current?.album)
        guard let ns = source?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.18, b > 0.15 else { return nil }
        return (Color(nsColor: ns), 0.30 * Double(min(1, s)))
    }
}
