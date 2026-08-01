import SwiftUI

/// App-wide configuration: SMB share, Plex server, TMDB key.
/// Values persist to UserDefaults; `onSaved` restarts the engine.
struct SettingsView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var plexURL = ""
    @State private var plexToken = ""
    @State private var tmdbKey = ""

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
                    TextField("Server URL", text: $plexURL)
                    SecureField("Token", text: $plexToken)
                } header: {
                    Text("Plex (optional)")
                } footer: {
                    Text("plex.tv → account → your server's X-Plex-Token. Leave empty to use the file share only.")
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
