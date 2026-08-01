import SwiftUI

/// Netflix-style home: hero banner + horizontal carousels on a dark canvas.
struct BrowseView: View {
    @ObservedObject var streamer: StreamerManager
    /// Reloads the library whenever this changes (e.g. after playback ends).
    var refreshTick: Int = 0
    let onPlay: (URL, String, String, Double?) -> Void   // url, title, progress key, resume secs

    @State private var movies: [StreamerManager.LibraryMovie] = []
    @State private var shows: [StreamerManager.LibraryShow] = []
    @State private var episodes: [StreamerManager.LibraryEpisode] = []
    @State private var selectedShow: StreamerManager.LibraryShow?
    @State private var scanning = false
    @State private var showFiles = false
    @State private var plexUsers: [StreamerManager.PlexUser] = []
    @State private var pinPromptUser: StreamerManager.PlexUser?
    @State private var pinInput = ""
    @AppStorage("plexActiveUserName") private var activeUserName = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea()

            if movies.isEmpty && shows.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        hero
                        if !continueWatching.isEmpty {
                            carousel("Continue Watching", items: continueWatching)
                        }
                        carousel("Movies", items: movies.map(CardItem.movie))
                        showCarousel
                        Spacer(minLength: 30)
                    }
                }
            }

            toolbar
        }
        .task(id: "\(streamer.baseURL?.absoluteString ?? "")|\(refreshTick)") {
            await load()
            plexUsers = (try? await streamer.plexUsers()) ?? []
        }
        .alert("PIN for \(pinPromptUser?.title ?? "")", isPresented: .init(
            get: { pinPromptUser != nil },
            set: { if !$0 { pinPromptUser = nil } })
        ) {
            SecureField("PIN", text: $pinInput)
            Button("Switch") {
                if let user = pinPromptUser {
                    Task { await doSwitch(user, pin: pinInput) }
                }
                pinInput = ""
            }
            Button("Cancel", role: .cancel) { pinInput = "" }
        }
        .sheet(item: $selectedShow) { show in
            ShowDetailSheet(
                show: show,
                episodes: episodes.filter { $0.show == show.name },
                streamer: streamer,
                onPlay: onPlay)
        }
        .sheet(isPresented: $showFiles) {
            VStack(spacing: 0) {
                HStack {
                    Text("Files").font(.headline)
                    Spacer()
                    Button("Done") { showFiles = false }
                }
                .padding(10)
                BrowserView(streamer: streamer) { url, name in
                    showFiles = false
                    let key = sharePath(from: url)
                    onPlay(url, name, key, WatchProgress.position(for: key))
                }
            }
            .frame(width: 480, height: 560)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var toolbar: some View {
        HStack(spacing: 10) {
            if scanning { ProgressView().controlSize(.small) }
            if !plexUsers.isEmpty {
                Menu {
                    ForEach(plexUsers) { user in
                        Button {
                            switchTo(user)
                        } label: {
                            if user.title == activeUserName {
                                Label(user.title, systemImage: "checkmark")
                            } else {
                                Text(user.title)
                            }
                        }
                    }
                } label: {
                    Label(activeUserName.isEmpty ? "User" : activeUserName,
                          systemImage: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button {
                Task { await rescan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan library")
            Button {
                showFiles = true
            } label: {
                Image(systemName: "folder")
            }
            .help("Browse files")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.white.opacity(0.8))
        .padding(14)
    }

    private var featured: StreamerManager.LibraryMovie? {
        movies.filter { $0.backdrop_url != nil }
            .max { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    @ViewBuilder
    private var hero: some View {
        if let movie = featured {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: movie.backdrop_url.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .frame(height: 380)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(
                    colors: [.clear, .clear, Color(red: 0.08, green: 0.08, blue: 0.09)],
                    startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 10) {
                    Text(movie.title)
                        .font(.system(size: 42, weight: .heavy))
                        .shadow(radius: 8)
                    if let overview = movie.overview {
                        Text(overview)
                            .font(.callout)
                            .lineLimit(3)
                            .frame(maxWidth: 520, alignment: .leading)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    Button {
                        play(movie)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding(28)
            }
        }
    }

    enum CardItem: Identifiable {
        case movie(StreamerManager.LibraryMovie)
        case episode(StreamerManager.LibraryEpisode, showPoster: String?)

        var id: String {
            switch self {
            case .movie(let m): return "m\(m.id)"
            case .episode(let e, _): return "e\(e.id)"
            }
        }

        var poster: String? {
            switch self {
            case .movie(let m): return m.poster_url
            case .episode(_, let p): return p
            }
        }

        var label: String {
            switch self {
            case .movie(let m): return m.title
            case .episode(let e, _):
                return "\(e.show) S\(e.season)E\(e.episode)"
            }
        }
    }

    /// Server-driven: Plex viewOffsets are the source of truth, ordered by
    /// most recently watched. Local-only items fall back to the local store.
    private var continueWatching: [CardItem] {
        let positions = WatchProgress.allPositions()
        let posterByShow = Dictionary(shows.map { ($0.name, $0.poster_url) }) { a, _ in a }

        var entries: [(UInt64, CardItem)] = []
        for m in movies {
            if let offset = m.view_offset_secs, offset > 30 {
                entries.append((m.last_viewed_at ?? 0, .movie(m)))
            } else if m.source == "local", positions[m.progress_key] != nil {
                entries.append((0, .movie(m)))
            }
        }
        for e in episodes {
            if let offset = e.view_offset_secs, offset > 30 {
                entries.append((e.last_viewed_at ?? 0, .episode(e, showPoster: posterByShow[e.show] ?? nil)))
            } else if e.source == "local", positions[e.progress_key] != nil {
                entries.append((0, .episode(e, showPoster: posterByShow[e.show] ?? nil)))
            }
        }
        return entries.sorted { $0.0 > $1.0 }.map(\.1)
    }

    private func carousel(_ title: String, items: [CardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        PosterCard(posterURL: item.poster, label: item.label) {
                            switch item {
                            case .movie(let m): play(m)
                            case .episode(let e, _): play(e)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
        }
    }

    private var showCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TV Shows")
                .font(.title3.bold())
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shows) { show in
                        PosterCard(posterURL: show.poster_url, label: show.name) {
                            selectedShow = show
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if scanning {
                ProgressView()
                Text("Scanning your library…").foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Nothing here yet", systemImage: "film.stack",
                    description: Text("Press ⟳ to scan the share"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func play(_ movie: StreamerManager.LibraryMovie) {
        if let url = streamer.resolveStream(movie.stream_url) {
            let resume = movie.view_offset_secs ?? WatchProgress.position(for: movie.progress_key)
            onPlay(url, movie.title, movie.progress_key, resume)
        }
    }

    private func play(_ ep: StreamerManager.LibraryEpisode) {
        if let url = streamer.resolveStream(ep.stream_url) {
            let resume = ep.view_offset_secs ?? WatchProgress.position(for: ep.progress_key)
            onPlay(url, "\(ep.show) S\(ep.season)E\(ep.episode)", ep.progress_key, resume)
        }
    }

    private func sharePath(from url: URL) -> String {
        let raw = url.path.removingPercentEncoding ?? url.path
        return raw.hasPrefix("/stream/") ? String(raw.dropFirst("/stream/".count)) : raw
    }

    private func load() async {
        guard streamer.baseURL != nil else { return }
        movies = (try? await streamer.libraryMovies()) ?? []
        shows = (try? await streamer.libraryShows()) ?? []
        episodes = (try? await streamer.libraryEpisodes()) ?? []
    }

    private func switchTo(_ user: StreamerManager.PlexUser) {
        if user.protected {
            pinPromptUser = user
        } else {
            Task { await doSwitch(user, pin: nil) }
        }
    }

    private func doSwitch(_ user: StreamerManager.PlexUser, pin: String?) async {
        if await streamer.switchPlexUser(uuid: user.uuid, pin: pin) {
            activeUserName = user.title
        }
    }

    private func rescan() async {
        scanning = true
        defer { scanning = false }
        _ = try? await streamer.scanLibrary()
        await load()
    }
}

/// Poster with Netflix-style hover pop.
struct PosterCard: View {
    let posterURL: String?
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: posterURL.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.06))
                        Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 148, height: 222)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(hovering ? 0.7 : 0.3), radius: hovering ? 14 : 5, y: 4)

                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .scaleEffect(hovering ? 1.07 : 1.0)
            .animation(.spring(duration: 0.25), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Episode picker for a show, grouped by season, over the show's backdrop.
struct ShowDetailSheet: View {
    let show: StreamerManager.LibraryShow
    let episodes: [StreamerManager.LibraryEpisode]
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String, String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss

    private var seasons: [(UInt16, [StreamerManager.LibraryEpisode])] {
        Dictionary(grouping: episodes, by: \.season)
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: show.backdrop_url.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .frame(height: 200)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.name).font(.largeTitle.bold())
                        Text("\(show.episode_count) episodes")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }

            List {
                if let overview = show.overview {
                    Text(overview).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(seasons, id: \.0) { season, eps in
                    Section("Season \(season)") {
                        ForEach(eps) { ep in
                            Button {
                                if let url = streamer.resolveStream(ep.stream_url) {
                                    dismiss()
                                    let resume = ep.view_offset_secs
                                        ?? WatchProgress.position(for: ep.progress_key)
                                    onPlay(url, "\(show.name) S\(ep.season)E\(ep.episode)", ep.progress_key, resume)
                                }
                            } label: {
                                HStack {
                                    Text(String(format: "E%02d", ep.episode))
                                        .font(.body.monospacedDigit())
                                    Spacer()
                                    if WatchProgress.position(for: ep.progress_key) != nil {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 640)
        .preferredColorScheme(.dark)
    }
}
