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
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerView(player: player)
                if player.mediaTitle.isEmpty {
                    Text("Open a video file (⌘O) or drop one here")
                        .foregroundStyle(.secondary)
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
