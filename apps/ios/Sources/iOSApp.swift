import SwiftUI

@main
struct MediaPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var core = CoreClient()
    @StateObject private var player = MPVPlayer()
    @State private var showingPlayer = false
    @State private var nowPlaying = ""

    var body: some View {
        NavigationStack {
            if core.baseURL == nil {
                ConnectView(core: core)
            } else {
                LibraryListView(core: core) { url, name in
                    nowPlaying = name
                    showingPlayer = true
                    player.load(url: url)
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            PlayerScreen(player: player, title: nowPlaying) {
                player.togglePauseIfPlaying()
                showingPlayer = false
            }
        }
    }
}

private extension MPVPlayer {
    func togglePauseIfPlaying() {
        if !isPaused { togglePause() }
    }
}

struct ConnectView: View {
    @ObservedObject var core: CoreClient
    @AppStorage("server") private var server = ""
    @AppStorage("share") private var share = ""
    @AppStorage("username") private var username = ""
    // Dev convenience: prefill via `simctl launch --setenv MEDIAPLAYER_PASSWORD=…`
    @State private var password = ProcessInfo.processInfo.environment["MEDIAPLAYER_PASSWORD"] ?? ""
    @State private var connecting = false

    var body: some View {
        Form {
            Section("SMB Share") {
                TextField("Server", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Share", text: $share)
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
            }
            Button(connecting ? "Connecting…" : "Connect") {
                connecting = true
                core.connect(server: server, share: share, username: username, password: password)
            }
            .disabled(connecting || server.isEmpty || share.isEmpty)
            if let err = core.lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("MediaPlayer")
        .onChange(of: core.lastError) { connecting = false }
    }
}

struct LibraryListView: View {
    @ObservedObject var core: CoreClient
    let onPlay: (URL, String) -> Void

    @State private var movies: [CoreClient.LibraryMovie] = []
    @State private var episodes: [CoreClient.LibraryEpisode] = []
    @State private var scanning = false

    var body: some View {
        List {
            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { movie in
                        Button {
                            if let url = core.streamURL(path: movie.path) {
                                onPlay(url, movie.title)
                            }
                        } label: {
                            HStack {
                                Text(movie.title)
                                Spacer()
                                if let year = movie.year {
                                    Text(String(year)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            if !episodes.isEmpty {
                Section("TV") {
                    ForEach(groupedShows, id: \.0) { show, eps in
                        NavigationLink("\(show) (\(eps.count))") {
                            EpisodeListView(show: show, episodes: eps, core: core, onPlay: onPlay)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button {
                Task {
                    scanning = true
                    _ = try? await core.scanLibrary()
                    await load()
                    scanning = false
                }
            } label: {
                if scanning { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await load() }
        .overlay {
            if movies.isEmpty && episodes.isEmpty && !scanning {
                ContentUnavailableView(
                    "Empty library", systemImage: "film.stack",
                    description: Text("Tap ⟳ to scan the share"))
            }
        }
    }

    private var groupedShows: [(String, [CoreClient.LibraryEpisode])] {
        Dictionary(grouping: episodes, by: \.show)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func load() async {
        movies = (try? await core.libraryMovies()) ?? []
        episodes = (try? await core.libraryEpisodes()) ?? []
    }
}

struct EpisodeListView: View {
    let show: String
    let episodes: [CoreClient.LibraryEpisode]
    @ObservedObject var core: CoreClient
    let onPlay: (URL, String) -> Void

    var body: some View {
        List(episodes) { ep in
            Button(String(format: "S%02dE%02d", ep.season, ep.episode)) {
                if let url = core.streamURL(path: ep.path) {
                    onPlay(url, "\(show) S\(ep.season)E\(ep.episode)")
                }
            }
            .tint(.primary)
        }
        .navigationTitle(show)
    }
}

struct PlayerScreen: View {
    @ObservedObject var player: MPVPlayer
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerView(player: player)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title)
                    }
                    .tint(.white.opacity(0.8))
                    Text(title).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Spacer()
                    if !player.hwdecCurrent.isEmpty {
                        Text(player.hwdecCurrent)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.3), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding()
                Spacer()
                controls
            }
        }
        .background(.black)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(action: { player.seek(to: max(player.timePos - 15, 0)) }) {
                Image(systemName: "gobackward.15")
            }
            .tint(.white)
            Button(action: { player.togglePause() }) {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
            }
            .tint(.white)
            Button(action: { player.seek(to: player.timePos + 30) }) {
                Image(systemName: "goforward.30")
            }
            .tint(.white)
            #if !os(tvOS)
            Slider(
                value: Binding(get: { player.timePos }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1))
            #else
            ProgressView(value: min(player.timePos, player.duration), total: max(player.duration, 1))
                .tint(.white)
            #endif
            Text(timeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.5))
    }

    private var timeString: String {
        func fmt(_ t: Double) -> String {
            guard t.isFinite, t > 0 else { return "0:00" }
            let s = Int(t)
            return s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                : String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(fmt(player.timePos)) / \(fmt(player.duration))"
    }
}
