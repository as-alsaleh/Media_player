import SwiftUI
import UniformTypeIdentifiers

@main
struct MediaPlayerApp: App {
    init() {
        // Running as a bare SwiftPM executable (no .app bundle) macOS treats
        // us as a background process; opt back into being a windowed app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @StateObject private var player = MPVPlayer()
    @StateObject private var streamer = StreamerManager()
    @State private var showPlayer = false
    @State private var nowPlaying = ""
    @State private var nowPlayingPath: String?
    @State private var pendingResume: Double?
    @State private var refreshTick = 0
    @State private var markers: [StreamerManager.PlexMarker] = []
    @State private var controlsVisible = true
    @State private var hideWork: DispatchWorkItem?
    @State private var showSettings = false

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if needsOnboarding {
                OnboardingView(streamer: streamer) {
                    refreshTick += 1
                    autoConnect()
                }
            } else {
                BrowseView(streamer: streamer, refreshTick: refreshTick,
                           onReconnect: autoConnect, onPlay: startPlayback)
            }

            // Player stays mounted so mpv's render surface survives; it is
            // just hidden while browsing.
            playerOverlay
                .opacity(showPlayer ? 1 : 0)
                .allowsHitTesting(showPlayer)
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear(perform: autoConnect)
        .onReceive(progressTimer) { _ in saveProgress() }
        .onChange(of: player.isPaused) { saveProgress() }
        .onChange(of: player.duration) {
            if let resume = pendingResume, player.duration > resume {
                player.seek(to: resume)
                pendingResume = nil
            }
        }
        .preferredColorScheme(.dark)
    }

    /// First run: nothing configured yet — show the Plex sign-in.
    private var needsOnboarding: Bool {
        _ = refreshTick  // re-evaluate after login
        let d = UserDefaults.standard
        let hasPlex = !(d.string(forKey: "plexToken") ?? "").isEmpty
        return !hasPlex && ShareStore.load() == nil
    }

    /// Marker (intro/credits/commercial) covering the current position.
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

    private func pokeControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        NSCursor.unhide()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            if !player.isPaused {
                withAnimation(.easeOut(duration: 0.4)) { controlsVisible = false }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func closePlayer() {
        if !player.isPaused { player.togglePause() }
        saveProgress(traktState: "stop")
        showPlayer = false
        refreshTick += 1  // re-pull library so Continue Watching updates
    }

    private var playerOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: player)
                .ignoresSafeArea()

            // Top gradient: back, title, codec badge.
            VStack {
                HStack(spacing: 12) {
                    Button(action: closePlayer) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Text(nowPlaying)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        showSettings.toggle()
                        pokeControls()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        PlayerSettingsView(player: player)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 30)
                .background(
                    LinearGradient(colors: [.black.opacity(0.65), .clear],
                                   startPoint: .top, endPoint: .bottom))
                Spacer()
            }
            .opacity(controlsVisible ? 1 : 0)

            // Skip marker / Next Episode button rides above the control bar.
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
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 28)
                        .padding(.bottom, controlsVisible ? 120 : 40)
                    }
                }
                .transition(.opacity)
            }

            // Bottom control bar.
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text(format(player.timePos))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        Slider(
                            value: Binding(
                                get: { player.timePos },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(player.duration, 1)
                        )
                        .tint(progressRed)
                        .controlSize(.small)
                        Text(format(player.duration))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    HStack(spacing: 26) {
                        Button { player.seek(to: max(player.timePos - 15, 0)) } label: {
                            Image(systemName: "gobackward.15").font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                        Button { player.togglePause() } label: {
                            Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 26))
                                .frame(width: 52, height: 52)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        Button { player.seek(to: player.timePos + 30) } label: {
                            Image(systemName: "goforward.30").font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 40)
                .padding(.bottom, 22)
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)

            // Minimal progress line while controls are hidden.
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
                .transition(.opacity)
            }
        }
        .background(playerShortcuts)
        .onContinuousHover { phase in
            if case .active = phase { pokeControls() }
        }
        .onAppear(perform: pokeControls)
        .onChange(of: player.isPaused) { if player.isPaused { pokeControls() } }
    }

    /// Hidden buttons that give the player standard keyboard control:
    /// ←/→ seek ∓10s, ↑/↓ volume, M mute, F fullscreen, Esc close.
    private var playerShortcuts: some View {
        Group {
            Button("") { player.seek(to: max(player.timePos - 10, 0)); pokeControls() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { player.seek(to: player.timePos + 10); pokeControls() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { player.adjustVolume(by: 5); pokeControls() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { player.adjustVolume(by: -5); pokeControls() }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { player.cycleMute() }
                .keyboardShortcut("m", modifiers: [])
            Button("") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
            Button("") { closePlayer() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
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

        player.onFileEnded = {
            if let next = NowPlaying.nextEpisode {
                next()
            } else {
                closePlayer()
            }
        }
    }

    private func saveProgress(traktState: String? = nil) {
        guard let path = nowPlayingPath, player.duration > 0 else { return }
        WatchProgress.save(path: path, position: player.timePos, duration: player.duration)
        // Mirror progress to Plex so its watch history stays in sync.
        if path.hasPrefix("plex:") {
            streamer.reportPlexProgress(
                ratingKey: String(path.dropFirst("plex:".count)),
                time: player.timePos,
                duration: player.duration,
                state: player.isPaused ? "paused" : "playing")
        }
        // And to Trakt, when connected.
        if let ident = NowPlaying.trakt {
            let state = traktState ?? (player.isPaused ? "pause" : "start")
            streamer.traktScrobble(
                state: state,
                progress: player.timePos / player.duration * 100,
                kind: ident.kind, tmdb: ident.tmdb,
                season: ident.season, episode: ident.episode)
        }
    }

    private func autoConnect() {
        if let config = ShareStore.load(),
           let password = ShareStore.password(for: config) {
            streamer.start(config: config, password: password)
        } else {
            // Plex-only (or onboarding): engine still hosts the login flow.
            streamer.startPlexOnly()
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
