import SwiftUI

/// App-wide configuration: SMB share, Plex server, TMDB key.
/// Values persist to UserDefaults; `onSaved` restarts the engine.
struct SettingsView: View {
    let onSaved: () -> Void
    var streamer: StreamerManager? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var server = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var plexURL = ""
    @State private var plexToken = ""
    @State private var tmdbKey = ""
    @State private var plexLoginState: String?
    @State private var polling = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Form {
                Section("File Share (SMB)") {
                    TextField("Server (IP or hostname)", text: $server)
                    TextField("Share name", text: $share)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section {
                    if streamer != nil {
                        Button {
                            Task { await signInWithPlex() }
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key.fill")
                                Text(polling ? "Waiting for plex.tv sign-in…" : "Sign in with Plex")
                                    .font(.system(size: 13.5, weight: .semibold))
                                if polling { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(polling)
                        if let state = plexLoginState {
                            Text(state).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Server URL", text: $plexURL)
                    SecureField("Token", text: $plexToken)
                } header: {
                    Text("Plex (optional)")
                } footer: {
                    Text("Sign in opens plex.tv in your browser and fills these automatically. Leave empty to use the file share only.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Section {
                    SecureField("API Key", text: $tmdbKey)
                } header: {
                    Text("TMDB (optional)")
                } footer: {
                    Text("Free key from themoviedb.org — adds posters and descriptions for file-share items.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    save()
                } label: {
                    Text("Save & Reconnect")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .disabled(server.isEmpty || share.isEmpty)
            }
            .formStyle(.grouped)
        }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    /// PIN flow: open plex.tv in the browser, poll until linked, then adopt
    /// the discovered server URL + token.
    private func signInWithPlex() async {
        guard let streamer else { return }
        polling = true
        defer { polling = false }
        plexLoginState = nil

        guard let pin = await streamer.plexLoginStart(),
              let url = URL(string: pin.auth_url) else {
            plexLoginState = "Couldn't reach plex.tv — check your connection."
            return
        }
        openURL(url)
        plexLoginState = "Complete the sign-in in your browser (code \(pin.code))."

        for _ in 0..<60 {   // up to ~3 minutes
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let result = await streamer.plexLoginPoll(id: pin.id) else { continue }
            if !result.pending {
                if let serverURL = result.server_url, let token = result.token {
                    plexURL = serverURL
                    plexToken = token
                    plexLoginState = "Signed in — found \(result.server_name ?? "your server"). Saving…"
                    save()
                } else {
                    plexLoginState = "Signed in, but no owned server found on the account."
                }
                return
            }
        }
        plexLoginState = "Sign-in timed out — try again."
    }

    private func load() {
        let d = UserDefaults.standard
        if let config = ShareStore.load() {
            server = config.server
            share = config.share
            username = config.username
        }
        password = d.string(forKey: "smbPassword")
            ?? d.string(forKey: "smbPasswordDev") ?? ""
        plexURL = d.string(forKey: "plexServerURL") ?? ""
        plexToken = d.string(forKey: "plexToken") ?? ""
        tmdbKey = d.string(forKey: "tmdbApiKey") ?? ""
    }

    private func save() {
        let d = UserDefaults.standard
        let config = ShareConfig(server: server, share: share, username: username)
        ShareStore.save(config, password: password)
        d.set(password, forKey: "smbPassword")
        d.set(plexURL, forKey: "plexServerURL")
        d.set(plexToken, forKey: "plexToken")
        d.set(tmdbKey, forKey: "tmdbApiKey")
        // A new admin token invalidates any switched-profile token.
        d.removeObject(forKey: "plexActiveToken")
        d.removeObject(forKey: "plexActiveUserName")
        dismiss()
        onSaved()
    }
}
