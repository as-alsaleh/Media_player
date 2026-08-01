import SwiftUI

/// Minimal settings: sign in with Plex, or see that you're signed in.
struct SettingsView: View {
    let onSaved: () -> Void
    var streamer: StreamerManager? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var status: String?
    @State private var polling = false
    @AppStorage("plexToken") private var plexToken = ""
    @AppStorage("plexServerName") private var plexServerName = ""

    var body: some View {
        VStack(spacing: 22) {
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

            Spacer()

            if !plexToken.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("Signed in to Plex")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    if !plexServerName.isEmpty {
                        Text(plexServerName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign out") { signOut() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else {
                VStack(spacing: 14) {
                    Button {
                        Task { await signInWithPlex() }
                    } label: {
                        HStack(spacing: 8) {
                            if polling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "person.badge.key.fill")
                            }
                            Text(polling ? "Waiting for plex.tv…" : "Sign in with Plex")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 28).padding(.vertical, 13)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(polling)

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 380, height: 340)
        #endif
        .preferredColorScheme(.dark)
    }

    private func signInWithPlex() async {
        guard let streamer else { return }
        polling = true
        defer { polling = false }
        status = nil

        guard let pin = await streamer.plexLoginStart(),
              let url = URL(string: pin.auth_url) else {
            status = "Couldn't reach plex.tv — check your connection."
            return
        }
        openURL(url)
        status = "Finish signing in in your browser."

        for _ in 0..<60 {   // up to ~3 minutes
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let result = await streamer.plexLoginPoll(id: pin.id) else { continue }
            if !result.pending {
                if let serverURL = result.server_url, let token = result.token {
                    let d = UserDefaults.standard
                    d.set(serverURL, forKey: "plexServerURL")
                    d.set(token, forKey: "plexToken")
                    d.set(result.server_name ?? "", forKey: "plexServerName")
                    d.removeObject(forKey: "plexActiveToken")
                    d.removeObject(forKey: "plexActiveUserName")
                    onSaved()
                } else {
                    status = "Signed in, but no Plex server found on the account."
                }
                return
            }
        }
        status = "Sign-in timed out — try again."
    }

    private func signOut() {
        let d = UserDefaults.standard
        for key in ["plexServerURL", "plexToken", "plexServerName",
                    "plexActiveToken", "plexActiveUserName"] {
            d.removeObject(forKey: key)
        }
        onSaved()
    }
}
