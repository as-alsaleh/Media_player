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

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if streamer.baseURL != nil {
                BrowseView(streamer: streamer, onPlay: startPlayback)
            } else {
                setup
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

    private var setup: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("MediaPlayer")
                    .font(.system(size: 40, weight: .heavy))
                ShareSetupView { config, password in
                    ShareStore.save(config, password: password)
                    streamer.start(config: config, password: password)
                }
                if let err = streamer.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    private var playerOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                PlayerView(player: player)
                controls
            }
            HStack {
                Button {
                    if !player.isPaused { player.togglePause() }
                    saveProgress()
                    showPlayer = false
                } label: {
                    Image(systemName: "chevron.backward.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                Text(nowPlaying).font(.headline).lineLimit(1)
                Spacer()
                if !player.hwdecCurrent.isEmpty {
                    Text(player.hwdecCurrent)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.25), in: Capsule())
                }
            }
            .padding(12)
            .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: { player.togglePause() }) {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut(.space, modifiers: [])

            Slider(
                value: Binding(
                    get: { player.timePos },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )

            Text("\(format(player.timePos)) / \(format(player.duration))")
                .font(.caption.monospacedDigit())
        }
        .padding(10)
        .background(.black)
    }

    private func startPlayback(url: URL, title: String, path: String) {
        saveProgress()
        nowPlaying = title
        nowPlayingPath = path
        pendingResume = WatchProgress.position(for: path)
        showPlayer = true
        player.load(url: url)
    }

    private func saveProgress() {
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
    }

    private func autoConnect() {
        guard let config = ShareStore.load(),
              let password = ShareStore.password(for: config)
        else { return }
        streamer.start(config: config, password: password)
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
