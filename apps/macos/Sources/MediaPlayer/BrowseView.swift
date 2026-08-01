import SwiftUI

let canvasColor = Color(red: 0.078, green: 0.078, blue: 0.086)

/// Netflix-style home: fixed top nav, cinematic hero, carousels.
struct BrowseView: View {
    @ObservedObject var streamer: StreamerManager
    /// Reloads the library whenever this changes (e.g. after playback ends).
    var refreshTick: Int = 0
    let onPlay: (URL, String, String, Double?) -> Void   // url, title, progress key, resume secs

    enum Tab: String, CaseIterable {
        case home = "Home"
        case movies = "Movies"
        case shows = "TV Shows"
    }

    @State private var tab: Tab = .home
    @State private var movies: [StreamerManager.LibraryMovie] = []
    @State private var shows: [StreamerManager.LibraryShow] = []
    @State private var episodes: [StreamerManager.LibraryEpisode] = []
    @State private var selectedShow: StreamerManager.LibraryShow?
    @State private var selectedMovie: StreamerManager.LibraryMovie?
    @State private var scanning = false
    @State private var showFiles = false
    @State private var plexUsers: [StreamerManager.PlexUser] = []
    @State private var pinPromptUser: StreamerManager.PlexUser?
    @State private var pinInput = ""
    @AppStorage("plexActiveUserName") private var activeUserName = ""

    var body: some View {
        ZStack(alignment: .top) {
            canvasColor.ignoresSafeArea()

            if movies.isEmpty && shows.isEmpty {
                emptyState
            } else {
                content
            }

            navBar
        }
        .task(id: "\(streamer.baseURL?.absoluteString ?? "")|\(refreshTick)") {
            await load()
            plexUsers = (try? await streamer.plexUsers()) ?? []
        }
        .sheet(item: $selectedShow) { show in
            ShowDetailSheet(
                show: show,
                episodes: episodes.filter { $0.show == show.name },
                streamer: streamer,
                onPlay: onPlay)
        }
        .sheet(item: $selectedMovie) { movie in
            MovieDetailSheet(movie: movie, streamer: streamer, onPlay: onPlay)
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Navigation bar

    private var navBar: some View {
        HStack(spacing: 22) {
            Text("MEDIAPLAYER")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(red: 0.9, green: 0.15, blue: 0.13))
                .kerning(1.5)

            ForEach(Tab.allCases, id: \.self) { t in
                Button(t.rawValue) {
                    withAnimation(.easeOut(duration: 0.2)) { tab = t }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: tab == t ? .bold : .regular))
                .foregroundStyle(tab == t ? .white : .white.opacity(0.65))
            }

            Spacer()

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
                          systemImage: "person.crop.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button { Task { await rescan() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Rescan library")
            Button { showFiles = true } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Browse files")
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 48)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            switch tab {
            case .home: homeContent
            case .movies: gridContent(items: movies.map(CardItem.movie))
            case .shows: showGrid
            }
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 34) {
            hero
            if !continueWatching.isEmpty {
                continueRow
            }
            carousel("Movies", items: movies.map(CardItem.movie))
            showCarousel
            Spacer(minLength: 40)
        }
    }

    private var featured: StreamerManager.LibraryMovie? {
        movies.filter { $0.backdrop_url != nil && !$0.watched }
            .max { ($0.year ?? 0) < ($1.year ?? 0) }
            ?? movies.first { $0.backdrop_url != nil }
    }

    @ViewBuilder
    private var hero: some View {
        if let movie = featured {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    AsyncImage(url: movie.backdrop_url.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.black)
                    }
                    .frame(width: geo.size.width, height: 480)
                    .clipped()
                }
                .frame(height: 480)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: canvasColor.opacity(0.85), location: 0.85),
                        .init(color: canvasColor, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom)
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .leading, endPoint: .trailing)

                VStack(alignment: .leading, spacing: 14) {
                    Text(movie.title)
                        .font(.system(size: 54, weight: .black))
                        .shadow(color: .black.opacity(0.8), radius: 10)
                    HStack(spacing: 10) {
                        if let year = movie.year {
                            Text(String(year))
                        }
                        if let dur = movie.duration_secs {
                            Text("\(Int(dur) / 60) min")
                        }
                        Text(movie.source == "plex" ? "PLEX" : "SMB")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.5), lineWidth: 1))
                    }
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    if let overview = movie.overview {
                        Text(overview)
                            .font(.system(size: 14.5))
                            .lineLimit(3)
                            .frame(maxWidth: 540, alignment: .leading)
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.8), radius: 5)
                    }
                    HStack(spacing: 10) {
                        Button {
                            play(movie)
                        } label: {
                            Label(movie.view_offset_secs != nil ? "Resume" : "Play",
                                  systemImage: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 28).padding(.vertical, 11)
                                .background(.white, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        Button {
                            selectedMovie = movie
                        } label: {
                            Label("More Info", systemImage: "info.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: - Cards & rows

    enum CardItem: Identifiable {
        case movie(StreamerManager.LibraryMovie)
        case episode(StreamerManager.LibraryEpisode, showPoster: String?)

        var id: String {
            switch self {
            case .movie(let m): return m.uid
            case .episode(let e, _): return e.uid
            }
        }

        var poster: String? {
            switch self {
            case .movie(let m): return m.poster_url
            case .episode(_, let p): return p
            }
        }

        var backdropOrPoster: String? {
            switch self {
            case .movie(let m): return m.backdrop_url ?? m.poster_url
            case .episode(_, let p): return p
            }
        }

        var label: String {
            switch self {
            case .movie(let m): return m.title
            case .episode(let e, _): return "\(e.show) S\(e.season)E\(e.episode)"
            }
        }

        var progress: Double? {
            switch self {
            case .movie(let m):
                guard let o = m.view_offset_secs, let d = m.duration_secs, d > 0 else { return nil }
                return o / d
            case .episode(let e, _):
                guard let o = e.view_offset_secs, let d = e.duration_secs, d > 0 else { return nil }
                return o / d
            }
        }
    }

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

    /// Landscape cards with progress bars, like Netflix's Continue Watching.
    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(continueWatching) { item in
                        ContinueCard(item: item) { tapped(item) }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
            }
        }
    }

    private func carousel(_ title: String, items: [CardItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        PosterCard(posterURL: item.poster, label: item.label,
                                   progress: item.progress) {
                            tappedInfo(item)
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 10)
            }
        }
    }

    private var showCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TV Shows")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shows) { show in
                        PosterCard(posterURL: show.poster_url, label: show.name, progress: nil) {
                            selectedShow = show
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 10)
            }
        }
    }

    private func gridContent(items: [CardItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 22) {
            ForEach(items) { item in
                PosterCard(posterURL: item.poster, label: item.label, progress: item.progress) {
                    tappedInfo(item)
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 70)
    }

    private var showGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 22) {
            ForEach(shows) { show in
                PosterCard(posterURL: show.poster_url, label: show.name, progress: nil) {
                    selectedShow = show
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 70)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 21, weight: .bold))
            .padding(.horizontal, 48)
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

    private func tapped(_ item: CardItem) {
        switch item {
        case .movie(let m): play(m)
        case .episode(let e, _): play(e)
        }
    }

    private func tappedInfo(_ item: CardItem) {
        switch item {
        case .movie(let m): selectedMovie = m
        case .episode(let e, _): play(e)
        }
    }

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

    private func load() async {
        guard streamer.baseURL != nil else { return }
        movies = (try? await streamer.libraryMovies()) ?? []
        shows = (try? await streamer.libraryShows()) ?? []
        episodes = (try? await streamer.libraryEpisodes()) ?? []
    }

    private func rescan() async {
        scanning = true
        defer { scanning = false }
        _ = try? await streamer.scanLibrary()
        await load()
    }
}

// MARK: - Cards

/// Portrait poster with hover pop, optional progress bar.
struct PosterCard: View {
    let posterURL: String?
    let label: String
    let progress: Double?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: posterURL.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.06))
                            Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 152, height: 228)
                    .clipped()

                    if let progress {
                        progressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(hovering ? 0.7 : 0), lineWidth: 2))
                .shadow(color: .black.opacity(hovering ? 0.8 : 0.35),
                        radius: hovering ? 16 : 5, y: 5)

                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(width: 152, alignment: .leading)
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.7))
            }
            .scaleEffect(hovering ? 1.08 : 1.0)
            .animation(.spring(duration: 0.22), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle()
                    .fill(Color(red: 0.9, green: 0.15, blue: 0.13))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3.5)
    }
}

/// Landscape Continue-Watching card with a red progress bar and play glyph.
struct ContinueCard: View {
    let item: BrowseView.CardItem
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    AsyncImage(url: item.backdropOrPoster.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.white.opacity(0.06))
                    }
                    .frame(width: 290, height: 163)
                    .clipped()

                    Circle()
                        .fill(.black.opacity(hovering ? 0.65 : 0.45))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white))
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))

                    VStack {
                        Spacer()
                        if let progress = item.progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.3))
                                    Rectangle()
                                        .fill(Color(red: 0.9, green: 0.15, blue: 0.13))
                                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(hovering ? 0.8 : 0.35),
                        radius: hovering ? 14 : 5, y: 4)

                Text(item.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .frame(width: 290, alignment: .leading)
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
            }
            .scaleEffect(hovering ? 1.05 : 1.0)
            .animation(.spring(duration: 0.22), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail sheets

/// Movie page: backdrop, play/resume, rating stars, watched toggle.
struct MovieDetailSheet: View {
    let movie: StreamerManager.LibraryMovie
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String, String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stars: Int = 0
    @State private var watched: Bool

    init(movie: StreamerManager.LibraryMovie,
         streamer: StreamerManager,
         onPlay: @escaping (URL, String, String, Double?) -> Void) {
        self.movie = movie
        self.streamer = streamer
        self.onPlay = onPlay
        _watched = State(initialValue: movie.watched)
    }

    private var ratingKey: String? {
        movie.progress_key.hasPrefix("plex:")
            ? String(movie.progress_key.dropFirst("plex:".count)) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: (movie.backdrop_url ?? movie.poster_url).flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .frame(height: 280)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(movie.title).font(.system(size: 34, weight: .black))
                        HStack(spacing: 10) {
                            if let year = movie.year { Text(String(year)) }
                            if let dur = movie.duration_secs { Text("\(Int(dur) / 60) min") }
                            if watched {
                                Label("Watched", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        if let url = streamer.resolveStream(movie.stream_url) {
                            dismiss()
                            let resume = movie.view_offset_secs
                                ?? WatchProgress.position(for: movie.progress_key)
                            onPlay(url, movie.title, movie.progress_key, resume)
                        }
                    } label: {
                        Label(movie.view_offset_secs != nil ? "Resume" : "Play",
                              systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 26).padding(.vertical, 9)
                            .background(.white, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    if let key = ratingKey {
                        Button {
                            watched.toggle()
                            streamer.plexSetWatched(ratingKey: key, watched: watched)
                        } label: {
                            Image(systemName: watched ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help(watched ? "Mark unwatched" : "Mark watched")

                        starRating(key: key)
                    }
                }

                if let overview = movie.overview {
                    Text(overview)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
        .background(canvasColor)
        .preferredColorScheme(.dark)
    }

    private func starRating(key: String) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    stars = i
                    streamer.plexRate(ratingKey: key, rating: Double(i * 2))
                } label: {
                    Image(systemName: i <= stars ? "star.fill" : "star")
                        .foregroundStyle(i <= stars ? .yellow : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .help("Rate on Plex")
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
                    Button { dismiss() } label: {
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
                            episodeRow(ep)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 640)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func episodeRow(_ ep: StreamerManager.LibraryEpisode) -> some View {
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
                if ep.watched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green.opacity(0.7))
                        .font(.caption)
                }
                Spacer()
                if let o = ep.view_offset_secs, let d = ep.duration_secs, d > 0 {
                    ProgressView(value: o / d)
                        .frame(width: 60)
                        .tint(Color(red: 0.9, green: 0.15, blue: 0.13))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
