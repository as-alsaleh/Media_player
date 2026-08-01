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
    @StateObject private var streamer = StreamerManager()
    @StateObject private var player = MPVPlayer()

    @AppStorage("server") private var server = ""
    @AppStorage("share") private var share = ""
    @AppStorage("username") private var username = ""
    @AppStorage("smbPassword") private var storedPassword = ""

    @State private var showPlayer = false
    @State private var nowPlaying = ""
    @State private var nowPlayingPath: String?
    @State private var pendingResume: Double?
    @State private var refreshTick = 0
    @State private var markers: [StreamerManager.PlexMarker] = []
    @State private var connecting = false

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if streamer.baseURL != nil {
                BrowseView(streamer: streamer, refreshTick: refreshTick, onPlay: startPlayback)
            } else {
                connectForm
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen(
                player: player,
                streamer: streamer,
                title: nowPlaying,
                markers: markers,
                onClose: {
                    if !player.isPaused { player.togglePause() }
                    saveProgress()
                    showPlayer = false
                    refreshTick += 1
                })
        }
        .onAppear {
            streamer.onUserSwitched = { startCore() }
            if !server.isEmpty, !share.isEmpty, !password.isEmpty {
                startCore()
            }
        }
        .onReceive(progressTimer) { _ in saveProgress() }
        .preferredColorScheme(.dark)
    }

    private var password: String {
        ProcessInfo.processInfo.environment["MEDIAPLAYER_PASSWORD"] ?? storedPassword
    }

    private var connectForm: some View {
        NavigationStack {
            Form {
                Section("SMB Share") {
                    TextField("Server", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Share", text: $share)
                        .textInputAutocapitalization(.never)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $storedPassword)
                }
                Button(connecting ? "Connecting…" : "Connect") {
                    startCore()
                }
                .disabled(connecting || server.isEmpty || share.isEmpty)
                if let err = streamer.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle("MediaPlayer")
        }
    }

    private func startCore() {
        connecting = true
        let db = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.sqlite")
        try? FileManager.default.createDirectory(
            at: db.deletingLastPathComponent(), withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let plexURL = defaults.string(forKey: "plexServerURL")
            ?? ProcessInfo.processInfo.environment["MEDIAPLAYER_PLEX_URL"]
        let adminToken = defaults.string(forKey: "plexToken")
            ?? ProcessInfo.processInfo.environment["MEDIAPLAYER_PLEX_TOKEN"]
        let activeToken = defaults.string(forKey: "plexActiveToken") ?? adminToken
        let tmdb = defaults.string(forKey: "tmdbApiKey")
            ?? ProcessInfo.processInfo.environment["MEDIAPLAYER_TMDB_KEY"]
        let (server, share, username, password) = (server, share, username, password)

        Task.detached(priority: .userInitiated) {
            do {
                let url = try startStreamer(
                    server: server, share: share, username: username,
                    password: password, dbPath: db.path, tmdbApiKey: tmdb,
                    plexUrl: plexURL, plexToken: activeToken, plexAdminToken: adminToken)
                await MainActor.run {
                    streamer.adopt(baseURL: URL(string: url))
                    connecting = false
                }
            } catch {
                await MainActor.run {
                    streamer.adopt(baseURL: nil, error: String(describing: error))
                    connecting = false
                }
            }
        }
    }

    private func startPlayback(url: URL, title: String, path: String, resume: Double?) {
        saveProgress()
        nowPlaying = title
        nowPlayingPath = path
        pendingResume = resume
        showPlayer = true
        player.load(url: url)

        markers = []
        if path.hasPrefix("plex:") {
            let key = String(path.dropFirst("plex:".count))
            Task { markers = await streamer.plexMarkers(ratingKey: key) }
        }

        player.onFileEnded = { [self] in
            if let next = NowPlaying.nextEpisode {
                next()
            } else {
                if !player.isPaused { player.togglePause() }
                saveProgress()
                showPlayer = false
                refreshTick += 1
            }
        }
    }

    private func saveProgress() {
        guard let path = nowPlayingPath, player.duration > 0 else { return }
        WatchProgress.save(path: path, position: player.timePos, duration: player.duration)
        if path.hasPrefix("plex:") {
            streamer.reportPlexProgress(
                ratingKey: String(path.dropFirst("plex:".count)),
                time: player.timePos,
                duration: player.duration,
                state: player.isPaused ? "paused" : "playing")
        }
    }
}

/// Fullscreen touch player: tap to toggle controls, gear opens settings.
struct PlayerScreen: View {
    @ObservedObject var player: MPVPlayer
    @ObservedObject var streamer: StreamerManager
    let title: String
    let markers: [StreamerManager.PlexMarker]
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var hideWork: DispatchWorkItem?

    private var activeMarker: StreamerManager.PlexMarker? {
        markers.first {
            player.timePos >= $0.start_secs && player.timePos < $0.end_secs - 1
        }
    }

    private func skipLabel(_ kind: String) -> String {
        switch kind {
        case "intro": return "Skip Intro"
        case "commercial": return "Skip Ad"
        case "credits": return "Skip Credits"
        default: return "Skip"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: player).ignoresSafeArea()

            // Double-tap edges to seek ±10s; single tap toggles controls.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.seek(to: max(player.timePos - 10, 0)) }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.seek(to: player.timePos + 10) }
            }
            .onTapGesture {
                withAnimation { controlsVisible.toggle() }
                if controlsVisible { scheduleHide() }
            }

            if let marker = activeMarker {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            if marker.kind == "credits", let next = NowPlaying.nextEpisode {
                                next()
                            } else {
                                player.seek(to: marker.end_secs)
                            }
                        } label: {
                            Text(marker.kind == "credits" && NowPlaying.nextEpisode != nil
                                 ? "Next Episode  ▶" : skipLabel(marker.kind))
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.black)
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, controlsVisible ? 130 : 40)
                    }
                }
            }

            if !controlsVisible, player.duration > 0 {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.15))
                            Rectangle()
                                .fill(accentGradient)
                                .frame(width: geo.size.width * min(player.timePos / player.duration, 1))
                        }
                    }
                    .frame(height: 3)
                }
                .ignoresSafeArea()
            }

            if controlsVisible {
                VStack {
                    HStack(spacing: 12) {
                        Button(action: onClose) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        Text(title).font(.headline).lineLimit(1)
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 15))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .background(
                        LinearGradient(colors: [.black.opacity(0.6), .clear],
                                       startPoint: .top, endPoint: .bottom))
                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Text(format(player.timePos))
                            CompatSlider(
                                value: Binding(
                                    get: { player.timePos },
                                    set: { player.seek(to: $0) }),
                                range: 0...max(player.duration, 1))
                                .tint(accentA)
                            Text(format(player.duration))
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white)

                        HStack(spacing: 40) {
                            Button { player.seek(to: max(player.timePos - 15, 0)) } label: {
                                Image(systemName: "gobackward.15").font(.system(size: 24))
                            }
                            Button { player.togglePause() } label: {
                                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 30))
                                    .frame(width: 60, height: 60)
                                    .background(.white.opacity(0.15), in: Circle())
                            }
                            Button { player.seek(to: player.timePos + 30) } label: {
                                Image(systemName: "goforward.30").font(.system(size: 24))
                            }
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
        .sheet(isPresented: $showSettings) {
            #if os(iOS)
            PlayerSettingsView(player: player)
                .presentationDetents([.medium, .large])
            #else
            PlayerSettingsView(player: player)
            #endif
        }
        .onAppear(perform: scheduleHide)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            if !player.isPaused {
                withAnimation { controlsVisible = false }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
