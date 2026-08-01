import SwiftUI

/// Infuse-style settings: General, Files, Playback, Audio, Languages.
/// Icon rows grouped into cards, monochrome design language.
struct SettingsView: View {
    let onSaved: () -> Void
    var streamer: StreamerManager? = nil
    @Environment(\.dismiss) private var dismiss

    private enum Section: String, CaseIterable {
        case general = "General"
        case files = "Files"
        case playback = "Playback"
        case audio = "Audio"
        case languages = "Languages"

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .files: return "folder.fill"
            case .playback: return "play.fill"
            case .audio: return "speaker.wave.2.fill"
            case .languages: return "globe"
            }
        }
    }
    @State private var section: Section = .general

    // Plex / account
    @AppStorage("plexToken") private var plexToken = ""
    @AppStorage("plexServerName") private var plexServerName = ""

    // Playback
    @AppStorage("introSkipMode") private var introSkipMode = "manual"
    @AppStorage("skipForwardSecs") private var skipForwardSecs = 30
    @AppStorage("skipBackSecs") private var skipBackSecs = 10
    @AppStorage("autoPlayNext") private var autoPlayNext = true

    // Audio
    @AppStorage("audioOutput") private var audioOutput = "auto"
    @AppStorage("audioPassthrough") private var audioPassthrough = false
    @AppStorage("defaultVolume") private var defaultVolume = 100.0
    @AppStorage("volumeBoost") private var volumeBoost = false

    // Languages
    @AppStorage("langAudio") private var langAudio = ""
    @AppStorage("langSubtitles") private var langSubtitles = ""
    @AppStorage("langMetadata") private var langMetadata = "en-US"
    @AppStorage("langArtwork") private var langArtwork = "en-US"

    // Files (SMB)
    @State private var smbServer = ShareStore.load()?.server ?? ""
    @State private var smbShare = ShareStore.load()?.share ?? ""
    @State private var smbUser = ShareStore.load()?.username ?? ""
    @State private var smbPassword = ""
    @State private var cacheCleared = false

    // Jellyfin (trickplay/seek-preview provider)
    @AppStorage("jellyfinURL") private var jellyfinURL = ""
    @AppStorage("jellyfinApiKey") private var jellyfinApiKey = ""

    /// Track-selection languages (mpv alang/slang code lists).
    private static let trackLanguages: [(String, String)] = [
        ("Auto", ""), ("English", "eng,en"), ("Arabic", "ara,ar"),
        ("French", "fra,fre,fr"), ("Spanish", "spa,es"), ("German", "deu,ger,de"),
        ("Italian", "ita,it"), ("Portuguese", "por,pt"), ("Russian", "rus,ru"),
        ("Turkish", "tur,tr"), ("Hindi", "hin,hi"), ("Japanese", "jpn,ja"),
        ("Korean", "kor,ko"), ("Chinese", "zho,chi,zh"),
    ]
    /// Metadata/artwork languages (TMDB BCP-47 tags).
    private static let metaLanguages: [(String, String)] = [
        ("English", "en-US"), ("Arabic", "ar"), ("French", "fr-FR"),
        ("Spanish", "es-ES"), ("German", "de-DE"), ("Italian", "it-IT"),
        ("Portuguese", "pt-BR"), ("Russian", "ru-RU"), ("Turkish", "tr-TR"),
        ("Hindi", "hi-IN"), ("Japanese", "ja-JP"), ("Korean", "ko-KR"),
        ("Chinese", "zh-CN"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            // Section chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Section.allCases, id: \.self) { s in
                        let selected = section == s
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { section = s }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: s.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(s.rawValue)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            }
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(selected ? AnyShapeStyle(.white)
                                                 : AnyShapeStyle(.white.opacity(0.07)),
                                        in: Capsule())
                            .foregroundStyle(selected ? .black : .white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .general: general
                    case .files: files
                    case .playback: playback
                    case .audio: audio
                    case .languages: languages
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 500, height: 580)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        card("Account") {
            if !plexToken.isEmpty {
                row("checkmark.seal.fill", "Plex",
                    caption: plexServerName.isEmpty ? "Signed in" : plexServerName) {
                    Button("Sign out") { signOutPlex() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else if let streamer {
                VStack(spacing: 8) {
                    PlexAuthButton(streamer: streamer) {
                        dismiss()
                        onSaved()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }

        card("Library") {
            Button {
                Task { _ = try? await streamer?.scanLibrary() }
                dismiss()
                onSaved()
            } label: {
                row("arrow.clockwise", "Refresh Library",
                    caption: "Re-pull everything from Plex and rescan files") {
                    chevron
                }
            }
            .buttonStyle(.plain)

            divider

            Button {
                FadeInImage.cache.removeAllCachedResponses()
                cacheCleared = true
            } label: {
                row("trash", cacheCleared ? "Artwork Cache Cleared" : "Clear Artwork Cache",
                    caption: "Posters and backdrops re-download as needed") {
                    if !cacheCleared { chevron }
                }
            }
            .buttonStyle(.plain)
            .disabled(cacheCleared)
        }

        card("About") {
            row("app.badge", "MediaPlayer", caption: "Open-source, powered by mpv") {
                Text("0.1")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Files

    @ViewBuilder
    private var files: some View {
        if let saved = ShareStore.load() {
            card("Connected Share") {
                row("externaldrive.fill.badge.checkmark",
                    "\(saved.server)/\(saved.share)",
                    caption: "Signed in as \(saved.username)") {
                    Button("Remove") {
                        UserDefaults.standard.removeObject(forKey: "savedShare")
                        smbServer = ""; smbShare = ""; smbUser = ""; smbPassword = ""
                        dismiss(); onSaved()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
        }

        card("Add a Network Share (SMB)") {
            VStack(spacing: 8) {
                field("Server", text: $smbServer, prompt: "192.168.1.10")
                field("Share", text: $smbShare, prompt: "media")
                field("Username", text: $smbUser, prompt: "user")
                HStack(spacing: 10) {
                    Text("Password")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 76, alignment: .leading)
                    SecureField("••••••••", text: $smbPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    let config = ShareConfig(server: smbServer, share: smbShare, username: smbUser)
                    ShareStore.save(config, password: smbPassword)
                    // Dev-build escape hatch: unsigned rebuilds stall Keychain ACL prompts.
                    UserDefaults.standard.set(smbPassword, forKey: "smbPassword")
                    dismiss()
                    onSaved()
                } label: {
                    Text("Connect")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.horizontal, 26).padding(.vertical, 9)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(smbServer.isEmpty || smbShare.isEmpty || smbUser.isEmpty)
                .padding(.top, 6)

                Text("Files on the share appear in the Files tab and, without Plex, in the library.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }

        card("Jellyfin (Seek Previews)") {
            VStack(spacing: 8) {
                field("Server", text: $jellyfinURL, prompt: "http://192.168.1.10:8096")
                field("API key", text: $jellyfinApiKey, prompt: "from Dashboard → API Keys")
                Text("Jellyfin's trickplay images power the mini picture when scrubbing the timeline. Reconnect (or restart the app) after changing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: - Playback

    @ViewBuilder
    private var playback: some View {
        card("Intros & Ads") {
            row("forward.end.fill", "Skip mode",
                caption: "Automatic jumps past intros and ads for you") {
                picker($introSkipMode, options: [
                    ("Off", "off"), ("Show button", "manual"), ("Automatic", "auto"),
                ])
            }
        }

        card("Seeking") {
            row("goforward.30", "Skip forward", caption: nil) {
                picker($skipForwardSecs, options: [
                    ("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30),
                    ("45 seconds", 45), ("60 seconds", 60), ("90 seconds", 90),
                ])
            }
            divider
            row("gobackward.10", "Skip back", caption: nil) {
                picker($skipBackSecs, options: [
                    ("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30),
                ])
            }
        }

        card("Episodes") {
            row("play.rectangle.on.rectangle.fill", "Autoplay next episode",
                caption: "Start the next episode when one ends") {
                prefToggle($autoPlayNext)
            }
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audio: some View {
        card("Output") {
            row("hifispeaker.fill", "Channels",
                caption: "5.1 needs an HDMI or AirPlay receiver") {
                picker($audioOutput, options: [
                    ("Auto", "auto"), ("Stereo (downmix)", "stereo"), ("5.1 Surround", "51"),
                ])
            }
            divider
            row("cable.connector", "Dolby passthrough",
                caption: "HDMI receivers only — mutes built-in speakers") {
                prefToggle($audioPassthrough)
            }
        }

        card("Levels") {
            row("speaker.wave.2.fill", "Volume", caption: nil) {
                HStack(spacing: 8) {
                    CompatSlider(value: $defaultVolume, range: 0...130)
                        .tint(.white)
                        .frame(width: 130)
                    Text("\(Int(defaultVolume))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 38, alignment: .trailing)
                }
            }
            divider
            row("dial.medium.fill", "Volume boost",
                caption: "Evens out quiet dialogue and loud scenes") {
                prefToggle($volumeBoost)
            }
        }
    }

    // MARK: - Languages

    @ViewBuilder
    private var languages: some View {
        card("Playback") {
            row("waveform", "Audio", caption: "Preferred audio track language") {
                picker($langAudio, options: Self.trackLanguages)
            }
            divider
            row("captions.bubble.fill", "Subtitles", caption: "Preferred subtitle language") {
                picker($langSubtitles, options: Self.trackLanguages)
            }
        }

        card("Library") {
            row("doc.text.fill", "Metadata", caption: "Titles and overviews from TMDB") {
                picker($langMetadata, options: Self.metaLanguages)
            }
            divider
            row("photo.fill", "Artwork", caption: "Poster language when available") {
                picker($langArtwork, options: Self.metaLanguages)
            }
        }

        Text("Plex items follow the Plex server's own language settings.")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .kerning(1.2)
                .padding(.leading, 6)
            VStack(spacing: 0, content: content)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.05), lineWidth: 1))
        }
    }

    private var divider: some View {
        Divider()
            .overlay(.white.opacity(0.05))
            .padding(.leading, 56)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.3))
    }

    private func row<Content: View>(_ icon: String, _ title: String,
                                    caption: String?,
                                    @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func picker<T: Hashable>(_ selection: Binding<T>,
                                     options: [(String, T)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { name, value in
                Text(name).tag(value)
            }
        }
        .labelsHidden()
        #if !os(tvOS)
        .pickerStyle(.menu)
        #endif
        .tint(.white.opacity(0.7))
        .fixedSize()
    }

    private func prefToggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value)
            .labelsHidden()
            #if !os(tvOS)
            .toggleStyle(.switch)
            #endif
            .tint(.white.opacity(0.35))
            .controlSize(.small)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 76, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
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
