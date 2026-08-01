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
    }
}

struct ContentView: View {
    @StateObject private var player = MPVPlayer()
    @StateObject private var streamer = StreamerManager()
    @State private var isDropTargeted = false
    @State private var showBrowser = true
    @State private var nowPlaying = ""
    @State private var nowPlayingPath: String?
    @State private var sidebarMode: SidebarMode = .library
    @State private var pendingResume: Double?

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    enum SidebarMode: String, CaseIterable {
        case library = "Library"
        case files = "Files"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(showBrowser ? .all : .detailOnly)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            playerPane
        }
        .onAppear(perform: autoConnect)
    }

    private var sidebar: some View {
        Group {
            if streamer.baseURL != nil {
                VStack(spacing: 0) {
                    Picker("", selection: $sidebarMode) {
                        ForEach(SidebarMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    Divider()
                    switch sidebarMode {
                    case .library:
                        LibraryView(streamer: streamer, onPlay: startPlayback)
                    case .files:
                        BrowserView(streamer: streamer, onPlay: startPlayback)
                    }
                }
            } else {
                ShareSetupView { config, password in
                    ShareStore.save(config, password: password)
                    streamer.start(config: config, password: password)
                }
                if let err = streamer.lastError {
                    Text(err).foregroundStyle(.red).font(.caption).padding()
                }
            }
        }
    }

    private var playerPane: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerView(player: player)
                if player.mediaTitle.isEmpty {
                    Text("Pick a video from the sidebar, drop a file here, or press ⌘O")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { player.load(url: url) } }
                }
                return true
            }

            controls
        }
        .background(KeyboardShortcuts(player: player))
        .onReceive(progressTimer) { _ in saveProgress() }
        .onChange(of: player.isPaused) { saveProgress() }
        .onChange(of: player.duration) {
            // Apply a pending resume once the file's duration is known.
            if let resume = pendingResume, player.duration > resume {
                player.seek(to: resume)
                pendingResume = nil
            }
        }
    }

    private func startPlayback(url: URL, name: String) {
        saveProgress()
        nowPlaying = name
        // Share-relative path = URL path after "/stream/".
        let raw = url.path.removingPercentEncoding ?? url.path
        nowPlayingPath = raw.hasPrefix("/stream/") ? String(raw.dropFirst("/stream/".count)) : nil
        pendingResume = nowPlayingPath.flatMap(WatchProgress.position(for:))
        player.load(url: url)
    }

    private func saveProgress() {
        guard let path = nowPlayingPath, player.duration > 0 else { return }
        WatchProgress.save(path: path, position: player.timePos, duration: player.duration)
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

            if !player.hwdecCurrent.isEmpty {
                Text(player.hwdecCurrent)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: Capsule())
                    .help("Active hardware decoder")
            }
        }
        .padding(10)
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

/// Hidden helper providing the ⌘O open-file shortcut.
private struct KeyboardShortcuts: View {
    let player: MPVPlayer

    var body: some View {
        Button("Open…") { openFile() }
            .keyboardShortcut("o")
            .hidden()
            .frame(width: 0, height: 0)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            player.load(url: url)
        }
    }
}
