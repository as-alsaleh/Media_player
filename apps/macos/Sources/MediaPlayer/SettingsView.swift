import SwiftUI

/// Minimal settings: Plex sign-in state and Trakt connection.
struct SettingsView: View {
    let onSaved: () -> Void
    var streamer: StreamerManager? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage("plexToken") private var plexToken = ""
    @AppStorage("plexServerName") private var plexServerName = ""
    @AppStorage("traktAccessToken") private var traktToken = ""
    @State private var traktStatus: String?
    @State private var traktPolling = false

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

            // Plex
            if !plexToken.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Signed in to Plex")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    if !plexServerName.isEmpty {
                        Text(plexServerName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign out") { signOutPlex() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let streamer {
                PlexAuthButton(streamer: streamer) {
                    dismiss()
                    onSaved()
                }
            }

            Divider().padding(.vertical, 4)

            // Trakt
            if !traktToken.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Trakt connected")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Button("Disconnect") {
                        traktToken = ""
                        UserDefaults.standard.removeObject(forKey: "traktRefreshToken")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Button {
                        Task { await connectTrakt() }
                    } label: {
                        HStack(spacing: 8) {
                            if traktPolling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "link")
                            }
                            Text(traktPolling ? "Waiting for trakt.tv…" : "Connect Trakt")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(traktPolling)
                    if let traktStatus {
                        Text(traktStatus)
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
        .frame(width: 380, height: 400)
        #endif
        .preferredColorScheme(.dark)
    }

    private func signOutPlex() {
        let d = UserDefaults.standard
        for key in ["plexServerURL", "plexToken", "plexServerName",
                    "plexActiveToken", "plexActiveUserName"] {
            d.removeObject(forKey: key)
        }
        dismiss()
        onSaved()
    }

    private func connectTrakt() async {
        guard let streamer else { return }
        let d = UserDefaults.standard
        guard let clientId = d.string(forKey: "traktClientId"), !clientId.isEmpty,
              let secret = d.string(forKey: "traktClientSecret"), !secret.isEmpty else {
            traktStatus = "Trakt needs API credentials first — create a free app at trakt.tv/oauth/applications."
            return
        }
        traktPolling = true
        defer { traktPolling = false }
        traktStatus = nil

        guard let code = await streamer.traktLoginStart(clientId: clientId) else {
            traktStatus = "Couldn't reach trakt.tv."
            return
        }
        // trakt.tv/activate/<code> lands with the code prefilled — one click to approve.
        if let url = URL(string: "\(code.verification_url)/\(code.user_code)") { openURL(url) }
        traktStatus = "Approve access in your browser (code \(code.user_code))."

        let interval = max(code.interval, 3)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            guard let result = await streamer.traktLoginPoll(
                clientId: clientId, clientSecret: secret, deviceCode: code.device_code)
            else { continue }
            if !result.pending {
                if let token = result.access_token {
                    traktToken = token
                    d.set(result.refresh_token ?? "", forKey: "traktRefreshToken")
                    traktStatus = nil
                }
                return
            }
        }
        traktStatus = "Trakt sign-in timed out — try again."
    }
}
