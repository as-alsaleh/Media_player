import SwiftUI

/// Minimal settings: Plex sign-in state and Trakt connection.
struct SettingsView: View {
    let onSaved: () -> Void
    var streamer: StreamerManager? = nil
    @Environment(\.dismiss) private var dismiss

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
}
