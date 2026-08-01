import SwiftUI

private let videoExtensions: Set<String> = [
    "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "flv",
]

/// Share browser with its own navigation state (path segments).
struct BrowserView: View {
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String) -> Void

    @State private var segments: [String] = []
    @State private var entries: [RemoteEntry] = []
    @State private var error: String?
    @State private var loading = false

    private var path: String { segments.joined(separator: "/") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: taskKey) { await reload() }
    }

    private var taskKey: String { "\(streamer.baseURL?.absoluteString ?? "")|\(path)" }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { _ = segments.popLast() }) {
                Image(systemName: "chevron.backward")
            }
            .disabled(segments.isEmpty)
            Text(segments.last ?? "Share")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView(
                "Can't browse", systemImage: "exclamationmark.triangle",
                description: Text(error))
        } else {
            List(entries) { entry in
                row(entry)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func row(_ entry: RemoteEntry) -> some View {
        if entry.is_dir {
            Button {
                segments.append(entry.name)
            } label: {
                Label(entry.name, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            let isVideo = videoExtensions.contains((entry.name as NSString).pathExtension.lowercased())
            Button {
                let childPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                if let url = streamer.streamURL(path: childPath) {
                    onPlay(url, entry.name)
                }
            } label: {
                HStack {
                    Label(entry.name, systemImage: isVideo ? "film" : "doc")
                        .lineLimit(1)
                    Spacer()
                    Text(formatSize(entry.size))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isVideo)
        }
    }

    private func reload() async {
        guard streamer.baseURL != nil else { return }
        loading = true
        defer { loading = false }
        do {
            entries = try await streamer.list(path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ShareSetupView: View {
    @State private var server = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    let onSave: (ShareConfig, String) -> Void

    var body: some View {
        Form {
            Section("SMB Share") {
                TextField("Server (IP or hostname)", text: $server)
                TextField("Share name", text: $share)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            Button("Connect") {
                onSave(ShareConfig(server: server, share: share, username: username), password)
            }
            .disabled(server.isEmpty || share.isEmpty || username.isEmpty)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 420)
        .onAppear {
            if let saved = ShareStore.load() {
                server = saved.server
                share = saved.share
                username = saved.username
                password = ShareStore.password(for: saved) ?? ""
            }
        }
    }
}
