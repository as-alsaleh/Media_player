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

    // SMB config lives in ShareStore: server/share/user in defaults, the
    // password in the Keychain (parity with macOS).

    @State private var showPlayer = false
    @State private var nowPlaying = ""
    @State private var nowPlayingPath: String?
    @State private var refreshTick = 0
    @State private var markers: [StreamerManager.PlexMarker] = []
    @State private var connecting = false

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Group {
                if needsOnboarding {
                    OnboardingView(streamer: streamer) {
                        refreshTick += 1
                        startCore()
                    }
                } else {
                    BrowseView(streamer: streamer, refreshTick: refreshTick,
                               onReconnect: startCore, onPlay: startPlayback)
                }
            }

            // The player stays mounted (hidden, not removed) so mpv's render
            // layer survives across plays — tearing it down would leave mpv
            // pointing at a deallocated CAMetalLayer on the next playback.
            // Same approach as the macOS app.
            PlayerScreen(
                player: player,
                streamer: streamer,
                title: nowPlaying,
                markers: markers,
                active: showPlayer,
                onClose: {
                    if !player.isPaused { player.togglePause() }
                    saveProgress()
                    showPlayer = false
                    refreshTick += 1
                })
                .opacity(showPlayer ? 1 : 0)
                .allowsHitTesting(showPlayer)
                .ignoresSafeArea()
        }
        .onAppear {
            migrateLegacySMBConfig()
            streamer.onUserSwitched = { startCore() }
            startCore()
        }
        .onReceive(progressTimer) { _ in saveProgress() }
        .preferredColorScheme(.dark)
    }

    private var needsOnboarding: Bool {
        _ = refreshTick
        let d = UserDefaults.standard
        let hasPlex = !(d.string(forKey: "plexServerURL") ?? (ProcessInfo.processInfo.environment["MEDIAPLAYER_PLEX_URL"] ?? "")).isEmpty
        let hasJellyfin = !(d.string(forKey: "jellyfinUserToken") ?? "").isEmpty
        return !hasPlex && !hasJellyfin && ShareStore.load() == nil
    }

    /// Pre-Keychain builds kept the SMB config (and password, in plaintext)
    /// in UserDefaults. Move it into ShareStore/Keychain once and scrub the
    /// plaintext copy.
    private func migrateLegacySMBConfig() {
        let d = UserDefaults.standard
        let legacyPassword = d.string(forKey: "smbPassword") ?? ""
        if ShareStore.load() == nil,
           let server = d.string(forKey: "server"), !server.isEmpty {
            let config = ShareConfig(server: server,
                                     share: d.string(forKey: "share") ?? "",
                                     username: d.string(forKey: "username") ?? "")
            ShareStore.save(config, password: legacyPassword)
        } else if let config = ShareStore.load(), !legacyPassword.isEmpty {
            ShareStore.save(config, password: legacyPassword)
        }
        d.removeObject(forKey: "smbPassword")
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
        let jellyfinURL = defaults.string(forKey: "jellyfinURL")
        let jellyfinKey = defaults.string(forKey: "jellyfinApiKey")
        let saved = ShareStore.load()
        let (server, share, username) = (saved?.server ?? "", saved?.share ?? "", saved?.username ?? "")
        let password = ProcessInfo.processInfo.environment["MEDIAPLAYER_PASSWORD"]
            ?? saved.flatMap { ShareStore.password(for: $0) } ?? ""

        Task.detached(priority: .userInitiated) {
            do {
                let url = try startStreamer(
                    server: server, share: share, username: username,
                    password: password, dbPath: db.path, tmdbApiKey: tmdb,
                    plexUrl: plexURL, plexToken: activeToken, plexAdminToken: adminToken,
                    jellyfinUrl: jellyfinURL, jellyfinApiKey: jellyfinKey,
                    jellyfinUserToken: defaults.string(forKey: "jellyfinUserToken"),
                    jellyfinUserId: defaults.string(forKey: "jellyfinUserId"))
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
        showPlayer = true
        Prefs.apply(to: player)
        // mpv's own start option resumes reliably — including replaying the
        // same file, where waiting on a duration change never fires.
        player.setString("start", resume.map { String(format: "+%.1f", $0) } ?? "none")
        player.load(url: url)

        markers = []
        // Guard every async fetch against title switches mid-flight.
        if path.hasPrefix("plex:") {
            let key = String(path.dropFirst("plex:".count))
            Task {
                let m = await streamer.plexMarkers(ratingKey: key)
                if nowPlayingPath == path { markers = m }
            }
            Task {
                await attachSubtitles(await streamer.plexSubtitles(ratingKey: key),
                                      forPath: path)
            }
        } else if path.hasPrefix("jf:") {
            let item = String(path.dropFirst("jf:".count))
            Task {
                let m = await streamer.jellyfinMarkers(itemId: item)
                if nowPlayingPath == path { markers = m }
            }
            Task {
                await attachSubtitles(await streamer.jellyfinSubtitles(itemId: item),
                                      forPath: path)
            }
        }

        player.onFileEnded = { [self] in
            if Prefs.autoPlayNext, let next = NowPlaying.nextEpisode {
                next()
            } else {
                if !player.isPaused { player.togglePause() }
                saveProgress()
                showPlayer = false
                refreshTick += 1
            }
        }
    }

    private func attachSubtitles(_ subs: [StreamerManager.PlexSubtitle],
                                 forPath path: String) async {
        guard !subs.isEmpty else { return }
        for _ in 0..<40 where player.duration <= 0 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // The wait may have been satisfied by a different file.
        guard nowPlayingPath == path else { return }
        let pref = Prefs.langSubtitles.split(separator: ",").map(String.init)
        var selected = false
        for sub in subs {
            let matches = !pref.isEmpty && (sub.lang.map { lang in
                pref.contains { lang.hasPrefix($0) || $0.hasPrefix(lang) }
            } ?? false)
            player.addSubtitle(url: sub.url, title: sub.title, lang: sub.lang,
                               select: matches && !selected)
            if matches { selected = true }
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
        } else if path.hasPrefix("jf:") {
            streamer.reportJellyfinProgress(
                itemId: String(path.dropFirst("jf:".count)),
                time: player.timePos,
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
    /// False while the (always-mounted) player is hidden behind the browse
    /// UI — gates tvOS focus so a hidden player can't trap the remote.
    var active: Bool = true
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

    private func skipIcon(back: Bool) -> String {
        let secs = back ? Prefs.skipBackSecs : Prefs.skipForwardSecs
        let known = [5, 10, 15, 30, 45, 60, 75, 90].contains(secs) ? "\(secs)" : ""
        return back ? "gobackward.\(known.isEmpty ? "minus" : known)"
                    : "goforward.\(known.isEmpty ? "plus" : known)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: player).ignoresSafeArea()

            // Double-tap edges to seek; single tap toggles controls.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.seek(to: max(player.timePos - Double(Prefs.skipBackSecs), 0)) }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.seek(to: player.timePos + Double(Prefs.skipForwardSecs)) }
            }
            .onTapGesture {
                withAnimation { controlsVisible.toggle() }
                if controlsVisible { scheduleHide() }
            }
            .onChange(of: player.timePos) {
                guard Prefs.introSkipMode == "auto",
                      let marker = activeMarker, marker.kind != "credits" else { return }
                player.seek(to: marker.end_secs)
            }

            if let marker = activeMarker, Prefs.introSkipMode != "off" {
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
                                .fill(progressRed)
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
                                .tint(progressRed)
                            Text(format(player.duration))
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white)

                        HStack(spacing: 40) {
                            Button { player.seek(to: max(player.timePos - Double(Prefs.skipBackSecs), 0)) } label: {
                                Image(systemName: skipIcon(back: true)).font(.system(size: 24))
                            }
                            Button { player.togglePause() } label: {
                                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 30))
                                    .frame(width: 60, height: 60)
                                    .background(.white.opacity(0.15), in: Circle())
                            }
                            Button { player.seek(to: player.timePos + Double(Prefs.skipForwardSecs)) } label: {
                                Image(systemName: skipIcon(back: false)).font(.system(size: 24))
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
        #if os(tvOS)
        // Siri Remote: Menu backs out (controls first, then the player),
        // play/pause does what it says, select toggles the control bar.
        .onExitCommand {
            if controlsVisible {
                withAnimation { controlsVisible = false }
            } else {
                onClose()
            }
        }
        .onPlayPauseCommand { player.togglePause() }
        // Focusable only while fronted AND the control bar is hidden — when
        // controls are up, focus belongs to their buttons, not this trap.
        .focusable(active && !controlsVisible)
        .onMoveCommand { direction in
            switch direction {
            case .left: player.seek(to: max(player.timePos - Double(Prefs.skipBackSecs), 0))
            case .right: player.seek(to: player.timePos + Double(Prefs.skipForwardSecs))
            case .down:
                withAnimation { controlsVisible = true }
                scheduleHide()
            default: break
            }
        }
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
