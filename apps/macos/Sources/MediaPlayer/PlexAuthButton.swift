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

/// Jellyfin sign-in: server address, then the server's user tiles.
/// Passwordless users sign in with one tap; others get a password field.
struct JellyfinAuthView: View {
    @ObservedObject var streamer: StreamerManager
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("jellyfinURL") private var serverURL = ""
    @State private var users: [StreamerManager.JellyfinUser] = []
    @State private var pickedUser: StreamerManager.JellyfinUser?
    @State private var password = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Sign in with Jellyfin")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                TextField("http://192.168.1.10:8096", text: $serverURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                Button("Connect") { Task { await loadUsers() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
                    .disabled(serverURL.isEmpty || busy)
            }

            if !users.isEmpty {
                Text("WHO'S WATCHING?")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .kerning(1.2)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                        ForEach(users) { user in
                            Button {
                                pickedUser = user
                                password = ""
                                if !user.has_password {
                                    Task { await login(user: user) }
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    Text(String(user.name.prefix(1)).uppercased())
                                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                                        .frame(width: 58, height: 58)
                                        .background(
                                            pickedUser?.id == user.id ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(.white.opacity(0.1)),
                                            in: Circle())
                                        .foregroundStyle(pickedUser?.id == user.id ? .black : .white)
                                    Text(user.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let user = pickedUser, user.has_password {
                HStack(spacing: 10) {
                    SecureField("Password for \(user.name)", text: $password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    Button("Sign in") { Task { await login(user: user) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .disabled(busy)
                }
            }

            if busy { ProgressView().controlSize(.small) }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440, height: 430)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
        .task { if !serverURL.isEmpty { await loadUsers() } }
    }

    private func loadUsers() async {
        busy = true
        defer { busy = false }
        status = nil
        users = await streamer.jellyfinUsers(base: serverURL)
        if users.isEmpty {
            status = "No users found — check the server address (and that the server shows users on its login screen)."
        }
    }

    private func login(user: StreamerManager.JellyfinUser) async {
        busy = true
        defer { busy = false }
        guard let login = await streamer.jellyfinLogin(
            base: serverURL, username: user.name, password: password)
        else {
            status = "Sign-in failed\(user.has_password ? " — wrong password?" : "")."
            return
        }
        let d = UserDefaults.standard
        d.set(serverURL, forKey: "jellyfinURL")
        d.set(login.token, forKey: "jellyfinUserToken")
        d.set(login.user_id, forKey: "jellyfinUserId")
        d.set(login.name, forKey: "jellyfinUserName")
        dismiss()
        onDone()
    }
}

/// First-run screen: the wordmark and the sign-in choices.
struct OnboardingView: View {
    @ObservedObject var streamer: StreamerManager
    let onDone: () -> Void
    @State private var showJellyfin = false

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
                Button {
                    showJellyfin = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key")
                        Text("Sign in with Jellyfin")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(40)
        }
        .sheet(isPresented: $showJellyfin) {
            JellyfinAuthView(streamer: streamer, onDone: onDone)
        }
        .preferredColorScheme(.dark)
    }
}
