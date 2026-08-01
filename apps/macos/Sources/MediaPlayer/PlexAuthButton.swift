import SwiftUI

/// The "Sign in with Plex" button + PIN polling flow, shared by onboarding
/// and Settings. Persists server URL/token on success and calls `onDone`.
struct PlexAuthButton: View {
    @ObservedObject var streamer: StreamerManager
    let onDone: () -> Void

    @State private var status: String?
    @State private var polling = false

    var body: some View {
        VStack(spacing: 14) {
            Button {
                Task { await signIn() }
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
            .disabled(polling || streamer.baseURL == nil)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @Environment(\.openURL) private var openURL

    private func signIn() async {
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
                    onDone()
                } else {
                    status = "Signed in, but no Plex server found on the account."
                }
                return
            }
        }
        status = "Sign-in timed out — try again."
    }
}

/// First-run screen: the wordmark and one button.
struct OnboardingView: View {
    @ObservedObject var streamer: StreamerManager
    let onDone: () -> Void

    var body: some View {
        ZStack {
            canvasColor.ignoresSafeArea()
            VStack(spacing: 26) {
                Text("mediaplayer")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Your movies and shows, beautifully played.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                PlexAuthButton(streamer: streamer, onDone: onDone)
                    .padding(.top, 10)
            }
            .padding(40)
        }
        .preferredColorScheme(.dark)
    }
}
