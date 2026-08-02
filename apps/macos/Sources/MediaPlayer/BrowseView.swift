import SwiftUI

// Pure monochrome: true black canvas, white accents, hairline strokes.
let canvasColor = Color(red: 0.02, green: 0.02, blue: 0.025)
let accentA = Color.white
let accentB = Color.white
let accentGradient = LinearGradient(
    colors: [.white, .white], startPoint: .leading, endPoint: .trailing)
/// Progress fills stay red so watch state pops against the monochrome UI.
let progressRed = Color(red: 0.95, green: 0.18, blue: 0.16)

#if os(macOS)
let edgePad: CGFloat = 48
#else
let edgePad: CGFloat = 20
#endif

extension View {
    /// `.onHover` shim — tvOS has no pointer; focus effects come for free.
    @ViewBuilder
    func onHoverCompat(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        self.onHover(perform: action)
        #endif
    }
}

/// Slider that degrades to −/+ buttons on tvOS (which has no Slider).
struct CompatSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEdit: () -> Void = {}

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 8) {
            Button { bump(-step) } label: { Image(systemName: "minus") }
            ProgressView(value: fraction)
            Button { bump(step) } label: { Image(systemName: "plus") }
        }
        #else
        Slider(value: $value, in: range) { _ in onEdit() }
        #endif
    }

    private var step: Double { (range.upperBound - range.lowerBound) / 20 }
    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (value - range.lowerBound) / span : 0
    }

    private func bump(_ delta: Double) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
        onEdit()
    }
}

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// Poster/backdrop image that fades in when loaded, cached to disk so
/// artwork is instant on relaunch and available offline.
struct FadeInImage: View {
    let url: URL?
    @State private var image: PlatformImage?

    /// Generous shared cache for artwork (memory + disk).
    static let cache: URLCache = URLCache(
        memoryCapacity: 64 * 1024 * 1024,
        diskCapacity: 512 * 1024 * 1024)

    var body: some View {
        ZStack {
            if let image {
                #if canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                #else
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                #endif
            } else {
                LinearGradient(
                    colors: [.white.opacity(0.04), .white.opacity(0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        // Serve straight from cache without a network round-trip when possible.
        if let cached = Self.cache.cachedResponse(for: request),
           let img = PlatformImage(data: cached.data) {
            image = img
            return
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let img = PlatformImage(data: data)
        else { return }
        Self.cache.storeCachedResponse(
            CachedURLResponse(response: response, data: data), for: request)
        withAnimation(.easeOut(duration: 0.25)) { image = img }
    }
}

/// Small frosted metadata chip (year, runtime, source…).
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.white.opacity(0.14), in: Capsule())
            .foregroundStyle(.white.opacity(0.9))
    }
}

/// What comes after the current item — set when an episode starts playing
/// so the player can offer "Next Episode" and auto-advance at the end.
@MainActor
enum NowPlaying {
    static var nextEpisode: (() -> Void)?
    static var nextLabel: String?
}

/// Horizontal card scroller with hover paging arrows on macOS
/// (Netflix-style). Touch platforms just swipe.
struct RowScroller<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    @State private var start = 0
    @State private var hovering = false
    private let step = 5

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        content(item).id(item.id)
                    }
                }
                .padding(.horizontal, edgePad)
                .padding(.vertical, 10)
            }
            #if os(macOS)
            .overlay(alignment: .leading) { arrow(left: true, proxy: proxy) }
            .overlay(alignment: .trailing) { arrow(left: false, proxy: proxy) }
            .onHoverCompat { hovering = $0 }
            #endif
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func arrow(left: Bool, proxy: ScrollViewProxy) -> some View {
        let canGo = left ? start > 0 : start + step < items.count
        if hovering, canGo {
            Button {
                start = left ? max(0, start - step)
                             : min(items.count - 1, start + step)
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(items[start].id, anchor: .leading)
                }
            } label: {
                Image(systemName: left ? "chevron.left" : "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 150)
                    .background(
                        LinearGradient(
                            colors: left ? [.black.opacity(0.8), .clear]
                                         : [.clear, .black.opacity(0.8)],
                            startPoint: .leading, endPoint: .trailing))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }
    #endif
}

/// Netflix-style home: fixed top nav, cinematic hero, carousels.
struct BrowseView: View {
    @ObservedObject var streamer: StreamerManager
    /// Reloads the library whenever this changes (e.g. after playback ends).
    var refreshTick: Int = 0
    /// Restart the engine after settings change or to retry a connection.
    var onReconnect: () -> Void = {}
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
    @State private var showSettings = false
    @State private var showDownloads = false
    @State private var plexUsers: [StreamerManager.PlexUser] = []
    @State private var pinPromptUser: StreamerManager.PlexUser?
    @State private var pinInput = ""
    @State private var searchText = ""
    @State private var heroIndex = 0
    @AppStorage("plexActiveUserName") private var activeUserName = ""
    @State private var jellyfinUsers: [StreamerManager.JellyfinUser] = []
    @State private var jfPasswordUser: StreamerManager.JellyfinUser?
    @State private var jfPasswordInput = ""
    @AppStorage("jellyfinUserName") private var jellyfinActiveName = ""
    @AppStorage("jellyfinURL") private var jellyfinBase = ""
    @AppStorage("jellyfinUserToken") private var jellyfinToken = ""

    /// Label for the user menu: the active Jellyfin user wins (Jellyfin is
    /// the primary source while signed in), else the Plex Home user.
    private var currentUserLabel: String {
        if !jellyfinToken.isEmpty, !jellyfinActiveName.isEmpty { return jellyfinActiveName }
        return activeUserName.isEmpty ? "User" : activeUserName
    }

    private func matches(_ title: String) -> Bool {
        searchText.isEmpty || title.localizedCaseInsensitiveContains(searchText)
    }

    /// A Home user other than the account owner is active.
    private var isRestrictedProfile: Bool {
        let d = UserDefaults.standard
        guard let active = d.string(forKey: "plexActiveToken"),
              let admin = d.string(forKey: "plexToken") else { return false }
        return active != admin
    }

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
            if !jellyfinBase.isEmpty, !jellyfinToken.isEmpty {
                jellyfinUsers = await streamer.jellyfinUsers(base: jellyfinBase)
            }
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
                    NowPlaying.nextEpisode = nil
                    NowPlaying.nextLabel = nil
                    let key = sharePath(from: url)
                    onPlay(url, name, key, WatchProgress.position(for: key))
                }
            }
            #if os(macOS)
            .frame(width: 480, height: 560)
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onSaved: onReconnect, streamer: streamer)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsSheet(streamer: streamer, onPlay: onPlay)
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
        .alert("Password for \(jfPasswordUser?.name ?? "")", isPresented: .init(
            get: { jfPasswordUser != nil },
            set: { if !$0 { jfPasswordUser = nil } })
        ) {
            SecureField("Password", text: $jfPasswordInput)
            Button("Switch") {
                if let user = jfPasswordUser {
                    let pw = jfPasswordInput
                    Task { await doJellyfinSwitch(user, password: pw) }
                }
                jfPasswordInput = ""
            }
            Button("Cancel", role: .cancel) { jfPasswordInput = "" }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Navigation bar

    private var navBar: some View {
        HStack(spacing: edgePad > 30 ? 22 : 12) {
            Text(edgePad > 30 ? "mediaplayer" : "mp")
                .font(.system(size: edgePad > 30 ? 19 : 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize()

            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { tab = t }
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                Capsule().fill(.white).opacity(tab == t ? 1 : 0))
                            .foregroundStyle(tab == t ? .black : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(3)
            .background(.white.opacity(0.07), in: Capsule())

            Spacer()

            if scanning { ProgressView().controlSize(.small) }
            if !plexUsers.isEmpty || !jellyfinUsers.isEmpty {
                Menu {
                    if !plexUsers.isEmpty {
                        Section("Plex") {
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
                        }
                    }
                    if !jellyfinUsers.isEmpty {
                        Section("Jellyfin") {
                            ForEach(jellyfinUsers) { user in
                                Button {
                                    switchToJellyfin(user)
                                } label: {
                                    if user.name == jellyfinActiveName {
                                        Label(user.name, systemImage: "checkmark")
                                    } else if user.has_password {
                                        Label(user.name, systemImage: "lock")
                                    } else {
                                        Text(user.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    #if os(macOS)
                    Label(currentUserLabel, systemImage: "person.crop.circle.fill")
                    #else
                    Image(systemName: "person.crop.circle.fill")
                    #endif
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
            }
            Button { Task { await rescan() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Rescan library")
            if !isRestrictedProfile {
                Button { showFiles = true } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Browse files")
            }
            if !isRestrictedProfile {
                Button { showDownloads = true } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Downloads")
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, edgePad)
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
            case .movies:
                searchField
                gridContent(items: movies.filter { matches($0.title) }.map(CardItem.movie))
            case .shows:
                searchField
                showGrid
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
        .padding(.horizontal, edgePad)
        .padding(.top, 64)
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 34) {
            hero
            if !continueWatching.isEmpty {
                continueRow
            }
            if !recentlyAdded.isEmpty {
                recentRow
            }
            carousel("Movies", items: movies.map(CardItem.movie))
            showCarousel
            Spacer(minLength: 40)
        }
    }

    enum HeroEntry: Identifiable {
        case movie(StreamerManager.LibraryMovie)
        case show(StreamerManager.LibraryShow)

        var id: String {
            switch self {
            case .movie(let m): return m.uid
            case .show(let s): return s.uid
            }
        }
    }

    /// Alternating mix of recent movies and shows with artwork,
    /// newest arrivals first.
    private var heroEntries: [HeroEntry] {
        let heroMovies = movies
            .filter { $0.backdrop_url != nil && !$0.watched }
            .sorted { ($0.added_at ?? 0, $0.year ?? 0) > ($1.added_at ?? 0, $1.year ?? 0) }
            .prefix(4)
            .map(HeroEntry.movie)
        let heroShows = shows
            .filter { $0.backdrop_url != nil }
            .sorted { ($0.added_at ?? 0) > ($1.added_at ?? 0) }
            .prefix(3)
            .map(HeroEntry.show)
        var mixed: [HeroEntry] = []
        for i in 0..<max(heroMovies.count, heroShows.count) {
            if i < heroMovies.count { mixed.append(heroMovies[i]) }
            if i < heroShows.count { mixed.append(heroShows[i]) }
        }
        return mixed
    }

    private let heroTimer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()
    @State private var heroHoldUntil = Date.distantPast

    /// Step the slideshow manually and hold off auto-advance for a while.
    private func stepHero(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        heroIndex = ((heroIndex % count) + delta + count) % count
        heroHoldUntil = Date().addingTimeInterval(12)
    }

    #if os(macOS)
    /// Invisible layer that pages the slideshow on two-finger trackpad
    /// scrolls (or a mouse wheel tilt). Uses a window-level event monitor so
    /// vertical scrolling of the page underneath keeps working.
    private struct ScrollSwipeCatcher: NSViewRepresentable {
        let onSwipe: (Int) -> Void

        func makeNSView(context: Context) -> Catcher { Catcher(onSwipe: onSwipe) }
        func updateNSView(_ view: Catcher, context: Context) { view.onSwipe = onSwipe }

        final class Catcher: NSView {
            var onSwipe: (Int) -> Void
            private var monitor: Any?
            private var accum: CGFloat = 0
            private var fired = false
            private var lastTime: TimeInterval = 0

            init(onSwipe: @escaping (Int) -> Void) {
                self.onSwipe = onSwipe
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { fatalError() }
            deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard monitor == nil, window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.observe(event)
                    return event
                }
            }

            private func observe(_ e: NSEvent) {
                guard e.window === window, e.momentumPhase == [] else { return }
                let loc = convert(e.locationInWindow, from: nil)
                guard bounds.contains(loc) else { return }
                // One page per gesture: reset on gesture start or after a lull.
                if e.phase == .began || e.timestamp - lastTime > 0.3 {
                    accum = 0
                    fired = false
                }
                lastTime = e.timestamp
                guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
                accum += e.scrollingDeltaX
                if !fired, abs(accum) > 60 {
                    fired = true
                    onSwipe(accum < 0 ? 1 : -1)
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private var hero: some View {
        let entries = heroEntries
        if !entries.isEmpty {
            let entry = entries[heroIndex % entries.count]
            ZStack(alignment: .bottomTrailing) {
                heroCard(entry)
                    .id(entry.id)
                    .transition(.opacity)

                // Page dots
                if entries.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(0..<entries.count, id: \.self) { i in
                            Circle()
                                .fill(.white.opacity(i == heroIndex % entries.count ? 0.95 : 0.35))
                                .frame(width: 6, height: 6)
                                .frame(width: 14, height: 14)   // generous tap target
                                .contentShape(Rectangle())
                                #if !os(tvOS)
                                .onTapGesture {
                                    heroIndex = i
                                    heroHoldUntil = Date().addingTimeInterval(12)
                                }
                                #endif
                        }
                    }
                    .padding(.trailing, edgePad + 22)
                    .padding(.bottom, 16)
                }
            }
            #if !os(tvOS)
            // Swipe / trackpad-drag between slides.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        if v.translation.width < -40 {
                            stepHero(1, count: entries.count)
                        } else if v.translation.width > 40 {
                            stepHero(-1, count: entries.count)
                        }
                    }
            )
            #endif
            #if os(macOS)
            // Two-finger trackpad scroll pages the slideshow too.
            .overlay(
                ScrollSwipeCatcher { delta in stepHero(delta, count: entries.count) }
                    .allowsHitTesting(false)
            )
            #endif
            .animation(.easeInOut(duration: 0.7), value: heroIndex)
            .onReceive(heroTimer) { _ in
                guard Date() >= heroHoldUntil else { return }
                heroIndex = (heroIndex + 1) % max(entries.count, 1)
            }
        }
    }

    @ViewBuilder
    private func heroCard(_ entry: HeroEntry) -> some View {
        switch entry {
        case .movie(let movie): movieHero(movie)
        case .show(let show): showHero(show)
        }
    }

    @ViewBuilder
    private func showHero(_ show: StreamerManager.LibraryShow) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                FadeInImage(url: show.backdrop_url.flatMap(URL.init))
                .frame(width: geo.size.width, height: 460)
                .clipped()
            }
            .frame(height: 460)

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
                Text(show.name)
                    .font(.system(size: 50, weight: .black, design: .rounded))
                    .shadow(color: .black.opacity(0.8), radius: 10)
                HStack(spacing: 8) {
                    Chip(text: "SERIES")
                    Chip(text: "\(show.episode_count) episodes")
                }
                if let overview = show.overview {
                    Text(overview)
                        .font(.system(size: 14.5))
                        .lineLimit(3)
                        .frame(maxWidth: 540, alignment: .leading)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.8), radius: 5)
                }
                HStack(spacing: 10) {
                    Button {
                        if let ep = nextUp(in: show) { play(ep) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .padding(.horizontal, 30).padding(.vertical, 12)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    Button {
                        selectedShow = show
                    } label: {
                        Label("More Info", systemImage: "info.circle")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 26)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.8), radius: 38, y: 16)
        .padding(.horizontal, edgePad)
        .padding(.top, 64)
    }

    @ViewBuilder
    private func movieHero(_ movie: StreamerManager.LibraryMovie) -> some View {
        if true {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    FadeInImage(url: movie.backdrop_url.flatMap(URL.init))
                    .frame(width: geo.size.width, height: 460)
                    .clipped()
                }
                .frame(height: 460)

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
                        .font(.system(size: 50, weight: .black, design: .rounded))
                        .shadow(color: .black.opacity(0.8), radius: 10)
                    HStack(spacing: 8) {
                        if let year = movie.year { Chip(text: String(year)) }
                        if let dur = movie.duration_secs { Chip(text: "\(Int(dur) / 60) min") }
                        Chip(text: movie.source == "local" ? "SMB" : movie.source.uppercased())
                        if movie.view_offset_secs != nil { Chip(text: "Resume") }
                    }
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
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .padding(.horizontal, 30).padding(.vertical, 12)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        Button {
                            selectedMovie = movie
                        } label: {
                            Label("More Info", systemImage: "info.circle")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 26)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.8), radius: 38, y: 16)
            .padding(.horizontal, edgePad)
            .padding(.top, 64)
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

        var watched: Bool {
            switch self {
            case .movie(let m): return m.watched
            case .episode(let e, _): return e.watched
            }
        }

        /// "34 min left" for in-progress items.
        var remainingText: String? {
            let pair: (Double?, Double?)
            switch self {
            case .movie(let m): pair = (m.view_offset_secs, m.duration_secs)
            case .episode(let e, _): pair = (e.view_offset_secs, e.duration_secs)
            }
            guard let offset = pair.0, let duration = pair.1, duration > offset else { return nil }
            return "\(Int((duration - offset) / 60)) min left"
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
            RowScroller(items: continueWatching) { item in
                ContinueCard(item: item) { tapped(item) }
            }
        }
    }

    /// Newest arrivals on the server, movies and shows mixed.
    private var recentlyAdded: [HeroEntry] {
        let m = movies.map { (($0.added_at ?? 0), HeroEntry.movie($0)) }
        let s = shows.map { (($0.added_at ?? 0), HeroEntry.show($0)) }
        return (m + s)
            .filter { $0.0 > 0 }
            .sorted { $0.0 > $1.0 }
            .prefix(15)
            .map(\.1)
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recently Added")
            RowScroller(items: recentlyAdded) { entry in
                switch entry {
                case .movie(let m):
                    PosterCard(posterURL: m.poster_url, label: m.title,
                               progress: nil, watched: m.watched) {
                        selectedMovie = m
                    }
                case .show(let s):
                    PosterCard(posterURL: s.poster_url, label: s.name, progress: nil) {
                        selectedShow = s
                    }
                }
            }
        }
    }

    private func carousel(_ title: String, items: [CardItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)
            RowScroller(items: items) { item in
                PosterCard(posterURL: item.poster, label: item.label,
                           progress: item.progress, watched: item.watched) {
                    tappedInfo(item)
                }
            }
        }
    }

    private var showCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TV Shows")
            RowScroller(items: shows) { show in
                PosterCard(posterURL: show.poster_url, label: show.name, progress: nil) {
                    selectedShow = show
                }
            }
        }
    }

    private func gridContent(items: [CardItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 22) {
            ForEach(items) { item in
                PosterCard(posterURL: item.poster, label: item.label, progress: item.progress, watched: item.watched) {
                    tappedInfo(item)
                }
            }
        }
        .padding(.horizontal, edgePad)
        .padding(.top, 16)
    }

    private var showGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 22) {
            ForEach(shows.filter { matches($0.name) }) { show in
                PosterCard(posterURL: show.poster_url, label: show.name, progress: nil) {
                    selectedShow = show
                }
            }
        }
        .padding(.horizontal, edgePad)
        .padding(.top, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .bold))
            .kerning(2.2)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, edgePad)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if scanning {
                ProgressView()
                Text("Scanning your library…").foregroundStyle(.secondary)
            } else if let error = streamer.lastError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Can't reach the server")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button {
                        onReconnect()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            } else if streamer.baseURL == nil {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
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
            NowPlaying.nextEpisode = nil
            NowPlaying.nextLabel = nil
            let resume = movie.view_offset_secs ?? WatchProgress.position(for: movie.progress_key)
            onPlay(url, movie.title, movie.progress_key, resume)
        }
    }

    private func play(_ ep: StreamerManager.LibraryEpisode) {
        guard let url = streamer.resolveStream(ep.stream_url) else { return }
        setNext(after: ep, in: episodes, streamer: streamer, onPlay: onPlay)
        let resume = ep.view_offset_secs ?? WatchProgress.position(for: ep.progress_key)
        onPlay(url, "\(ep.show) S\(ep.season)E\(ep.episode)", ep.progress_key, resume)
    }

    /// The episode Play should start for a show: the in-progress one,
    /// else the first unwatched, else episode one.
    private func nextUp(in show: StreamerManager.LibraryShow) -> StreamerManager.LibraryEpisode? {
        let eps = episodes
            .filter { $0.show == show.name }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        if let current = eps
            .filter({ $0.view_offset_secs != nil && !$0.watched })
            .max(by: { ($0.last_viewed_at ?? 0) < ($1.last_viewed_at ?? 0) }) {
            return current
        }
        if let lastWatched = eps.lastIndex(where: { $0.watched }),
           let next = eps[eps.index(after: lastWatched)...].first(where: { !$0.watched }) {
            return next
        }
        return eps.first(where: { !$0.watched }) ?? eps.first
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

    private func switchToJellyfin(_ user: StreamerManager.JellyfinUser) {
        if user.has_password {
            jfPasswordUser = user
        } else {
            Task { await doJellyfinSwitch(user, password: "") }
        }
    }

    private func doJellyfinSwitch(_ user: StreamerManager.JellyfinUser, password: String) async {
        guard let login = await streamer.jellyfinLogin(
            base: jellyfinBase, username: user.name, password: password) else { return }
        let d = UserDefaults.standard
        d.set(login.token, forKey: "jellyfinUserToken")
        d.set(login.user_id, forKey: "jellyfinUserId")
        d.set(login.name, forKey: "jellyfinUserName")
        onReconnect()   // restart the engine with the new user token
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

/// Register the episode that follows `ep` (same show, next in order) so the
/// player can chain into it. Clears the hook when `ep` is the last one.
@MainActor
func setNext(
    after ep: StreamerManager.LibraryEpisode,
    in episodes: [StreamerManager.LibraryEpisode],
    streamer: StreamerManager,
    onPlay: @escaping (URL, String, String, Double?) -> Void
) {
    let ordered = episodes
        .filter { $0.show == ep.show }
        .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    guard let idx = ordered.firstIndex(of: ep), idx + 1 < ordered.count else {
        NowPlaying.nextEpisode = nil
        NowPlaying.nextLabel = nil
        return
    }
    let next = ordered[idx + 1]
    NowPlaying.nextLabel = String(format: "S%02dE%02d", next.season, next.episode)
    NowPlaying.nextEpisode = {
        guard let url = streamer.resolveStream(next.stream_url) else { return }
        setNext(after: next, in: episodes, streamer: streamer, onPlay: onPlay)
        let resume = next.view_offset_secs ?? WatchProgress.position(for: next.progress_key)
        onPlay(url, "\(next.show) S\(next.season)E\(next.episode)", next.progress_key, resume)
    }
}

/// Portrait poster with hover pop, optional progress bar.
struct PosterCard: View {
    let posterURL: String?
    let label: String
    let progress: Double?
    var watched: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var labelVisible: Bool {
        #if os(macOS)
        hovering
        #else
        true
        #endif
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                FadeInImage(url: posterURL.flatMap(URL.init))
                    .frame(width: 152, height: 228)
                    .clipped()

                    if labelVisible {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer()
                            Text(label)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.bottom, progress != nil ? 10 : 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                                   startPoint: .top, endPoint: .bottom)
                                        .frame(height: 74), alignment: .bottom)
                        }
                        .transition(.opacity)
                    }

                    if let progress {
                        progressBar(progress)
                    }
                    if watched {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                                    .padding(5)
                            }
                            Spacer()
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(hovering ? 0.5 : 0.07), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: hovering ? .white.opacity(0.25) : .black.opacity(0.4),
                    radius: hovering ? 16 : 5, y: 5)
            .scaleEffect(hovering ? 1.07 : 1.0)
            .animation(.spring(duration: 0.22), value: hovering)
        }
        .buttonStyle(.plain)
        .onHoverCompat { hovering = $0 }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle()
                    .fill(progressRed)
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
            ZStack {
                FadeInImage(url: item.backdropOrPoster.flatMap(URL.init))
                    .frame(width: 290, height: 163)
                    .clipped()

                    VStack(alignment: .leading, spacing: 1) {
                        Spacer()
                        Text(item.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                        if let remaining = item.remainingText {
                            Text(remaining)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
                    .frame(width: 290, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.9)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 80), alignment: .bottom)

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
                                        .fill(progressRed)
                                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(hovering ? 0.5 : 0.07), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: hovering ? .white.opacity(0.25) : .black.opacity(0.4),
                    radius: hovering ? 14 : 5, y: 4)
            .scaleEffect(hovering ? 1.04 : 1.0)
            .animation(.spring(duration: 0.22), value: hovering)
        }
        .buttonStyle(.plain)
        .onHoverCompat { hovering = $0 }
    }
}

// MARK: - Detail sheets

/// Movie page: backdrop, play/resume, rating stars, watched toggle.
/// Offline downloads: live progress, play-from-disk, delete.
struct DownloadsSheet: View {
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String, String, Double?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [StreamerManager.DownloadEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)

            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Nothing downloaded yet")
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Use the download button on a movie to watch it offline.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in row(entry) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                entries = await streamer.downloadsList()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: StreamerManager.DownloadEntry) -> some View {
        HStack(spacing: 10) {
            FadeInImage(url: entry.posterURL)
                .frame(width: 34, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                switch entry.state {
                case "done":
                    Text(sizeLabel(entry.bytes_done))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                case "error":
                    Text("Failed — tap download again to retry")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                default:
                    ProgressView(value: entry.fraction ?? 0)
                        .tint(.white)
                    Text(progressLabel(entry))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            if entry.state == "done" {
                Button {
                    dismiss()
                    NowPlaying.nextEpisode = nil
                    NowPlaying.nextLabel = nil
                    onPlay(URL(fileURLWithPath: entry.file), entry.title,
                           entry.key, WatchProgress.position(for: entry.key))
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
            }
            Button {
                streamer.deleteDownload(key: entry.key)
                entries.removeAll { $0.key == entry.key }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sizeLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func progressLabel(_ e: StreamerManager.DownloadEntry) -> String {
        if let total = e.bytes_total, total > 0 {
            return "\(sizeLabel(e.bytes_done)) of \(sizeLabel(total))"
        }
        return sizeLabel(e.bytes_done)
    }
}

/// Critic (Rotten Tomatoes on Plex) and audience scores as compact badges.
/// Scores arrive 0–10; shown as percentages, hidden when absent.
struct RatingBadges: View {
    let critic: Double?
    let audience: Double?

    var body: some View {
        if let critic {
            HStack(spacing: 3) {
                Image(systemName: "rosette")
                    .foregroundStyle(critic >= 6 ? .green : .orange)
                Text("\(Int((critic * 10).rounded()))%")
            }
        }
        if let audience {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill")
                Text("\(Int((audience * 10).rounded()))%")
            }
        }
    }
}

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

    private var jellyfinItemId: String? {
        movie.progress_key.hasPrefix("jf:")
            ? String(movie.progress_key.dropFirst("jf:".count)) : nil
    }

    @State private var downloadQueued = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Full 16:9 backdrop — the whole picture, not a cropped strip.
                ZStack(alignment: .bottomLeading) {
                    FadeInImage(url: (movie.backdrop_url ?? movie.poster_url).flatMap(URL.init))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipped()
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: canvasColor.opacity(0.9), location: 0.92),
                            .init(color: canvasColor, location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(movie.title)
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .shadow(color: .black.opacity(0.8), radius: 8)
                        HStack(spacing: 10) {
                            if let year = movie.year { Text(String(year)) }
                            if let dur = movie.duration_secs { Text("\(Int(dur) / 60) min") }
                            RatingBadges(critic: movie.critic_rating,
                                         audience: movie.audience_rating)
                            if watched {
                                Label("Watched", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(22)
                }
                .overlay(alignment: .topTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Button {
                            if let url = streamer.resolveStream(movie.stream_url) {
                                dismiss()
                                // A movie never has a "next episode" — clear
                                // any leftover from a previous show.
                                NowPlaying.nextEpisode = nil
                                NowPlaying.nextLabel = nil
                                let resume = movie.view_offset_secs
                                    ?? WatchProgress.position(for: movie.progress_key)
                                onPlay(url, movie.title, movie.progress_key, resume)
                            }
                        } label: {
                            Label(movie.view_offset_secs != nil ? "Resume" : "Play",
                                  systemImage: "play.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .padding(.horizontal, 30).padding(.vertical, 11)
                                .background(.white, in: Capsule())
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

                            starRating { streamer.plexRate(ratingKey: key, rating: $0) }
                        } else if let item = jellyfinItemId {
                            Button {
                                watched.toggle()
                                streamer.jellyfinSetWatched(itemId: item, watched: watched)
                            } label: {
                                Image(systemName: watched ? "checkmark.circle.fill" : "checkmark.circle")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                            .help(watched ? "Mark unwatched" : "Mark watched")

                            starRating { streamer.jellyfinRate(itemId: item, rating: $0) }
                        }

                        Button {
                            let url = streamer.resolveStream(movie.stream_url)?.absoluteString
                                ?? movie.stream_url
                            streamer.startDownload(key: movie.progress_key, url: url,
                                                   title: movie.title,
                                                   poster: movie.poster_url)
                            downloadQueued = true
                        } label: {
                            Image(systemName: downloadQueued
                                  ? "checkmark.circle" : "arrow.down.circle")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help(downloadQueued ? "Added to Downloads" : "Download for offline")
                    }

                    if let o = movie.view_offset_secs, let d = movie.duration_secs, d > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                                GeometryReader { geo in
                                    Capsule().fill(progressRed)
                                        .frame(width: geo.size.width * o / d, height: 4)
                                }
                                .frame(height: 4)
                            }
                            Text("\(Int((d - o) / 60)) min left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let overview = movie.overview {
                        Text(overview)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 660)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
    }

    private func starRating(rate: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    stars = i
                    rate(Double(i * 2))
                } label: {
                    Image(systemName: i <= stars ? "star.fill" : "star")
                        .foregroundStyle(i <= stars ? .yellow : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .help("Rate on your server")
    }
}

/// Streaming-service style show page: full backdrop, season selector,
/// episode rows with artwork, titles and synopses.
struct ShowDetailSheet: View {
    let show: StreamerManager.LibraryShow
    let episodes: [StreamerManager.LibraryEpisode]
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String, String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSeason: UInt16?
    /// Keys queued for download from this sheet (shows the checkmark).
    @State private var downloadedKeys: Set<String> = []

    private var seasons: [(UInt16, [StreamerManager.LibraryEpisode])] {
        Dictionary(grouping: episodes, by: \.season)
            .mapValues { $0.sorted { $0.episode < $1.episode } }
            .sorted { $0.key < $1.key }
    }

    /// Default to the season the viewer is currently in.
    private var currentSeason: UInt16 {
        if let selectedSeason { return selectedSeason }
        let ordered = episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        if let current = ordered.first(where: { $0.view_offset_secs != nil && !$0.watched }) {
            return current.season
        }
        if let next = ordered.first(where: { !$0.watched }) { return next.season }
        return seasons.first?.0 ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 18) {
                    if let overview = show.overview {
                        Text(overview)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if seasons.count > 1 { seasonPicker }
                    LazyVStack(spacing: 14) {
                        if let eps = seasons.first(where: { $0.0 == currentSeason })?.1 {
                            ForEach(eps) { ep in
                                episodeRow(ep)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
        #if os(macOS)
        .frame(width: 760, height: 720)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            FadeInImage(url: show.backdrop_url.flatMap(URL.init))
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: canvasColor.opacity(0.9), location: 0.92),
                    .init(color: canvasColor, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(show.name)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .shadow(color: .black.opacity(0.8), radius: 8)
                HStack(spacing: 10) {
                    Text("SERIES")
                    Text("\(seasons.count == 1 ? "1 season" : "\(seasons.count) seasons")")
                    Text("\(show.episode_count) episodes")
                    RatingBadges(critic: show.critic_rating,
                                 audience: show.audience_rating)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(22)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
            }
            .buttonStyle(.plain)
            .padding(14)
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.0) { season, _ in
                    let selected = season == currentSeason
                    Button { selectedSeason = season } label: {
                        Text(season == 0 ? "Specials" : "Season \(season)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)),
                                        in: Capsule())
                            .foregroundStyle(selected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func episodeRow(_ ep: StreamerManager.LibraryEpisode) -> some View {
        Button {
            if let url = streamer.resolveStream(ep.stream_url) {
                dismiss()
                setNext(after: ep, in: episodes, streamer: streamer, onPlay: onPlay)
                let resume = ep.view_offset_secs
                    ?? WatchProgress.position(for: ep.progress_key)
                onPlay(url, "\(show.name) S\(ep.season)E\(ep.episode)", ep.progress_key, resume)
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                // Episode still with progress + watched state.
                ZStack {
                    FadeInImage(url: ep.thumb_url.flatMap(URL.init))
                        .frame(width: 192, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 6)
                }
                .overlay(alignment: .bottom) {
                    if let o = ep.view_offset_secs, let d = ep.duration_secs, d > 0 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                            Capsule().fill(progressRed)
                                .frame(width: max(6, 180 * o / d), height: 3)
                        }
                        .frame(width: 180)
                        .padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if ep.watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, .green.opacity(0.9))
                            .padding(5)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(ep.episode). \(ep.title ?? "Episode \(ep.episode)")")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        if let d = ep.duration_secs {
                            Text("\(Int(d / 60))m")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            let url = streamer.resolveStream(ep.stream_url)?.absoluteString
                                ?? ep.stream_url
                            streamer.startDownload(
                                key: ep.progress_key, url: url,
                                title: "\(show.name) S\(ep.season)E\(ep.episode)",
                                poster: ep.thumb_url)
                            downloadedKeys.insert(ep.progress_key)
                        } label: {
                            Image(systemName: downloadedKeys.contains(ep.progress_key)
                                  ? "checkmark.circle" : "arrow.down.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Download for offline")
                    }
                    if let overview = ep.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
