import SwiftUI

/// Infuse-style settings: General, Files, Playback, Audio, Languages.
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
        VStack(spacing: 18) {
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

            // Section chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Section.allCases, id: \.self) { s in
                        Button { section = s } label: {
                            Text(s.rawValue)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 15).padding(.vertical, 8)
                                .background(section == s ? AnyShapeStyle(.white)
                                                         : AnyShapeStyle(.white.opacity(0.08)),
                                            in: Capsule())
                                .foregroundStyle(section == s ? .black : .white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .general: general
                    case .files: files
                    case .playback: playback
                    case .audio: audio
                    case .languages: languages
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
        .background(canvasColor)
        .preferredColorScheme(.dark)
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        group("Plex Account") {
            if !plexToken.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in to Plex")
                            .font(.system(size: 14, weight: .semibold))
                        if !plexServerName.isEmpty {
                            Text(plexServerName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
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
        }

        group("Library") {
            Button {
                Task { _ = try? await streamer?.scanLibrary() }
                dismiss()
                onSaved()
            } label: {
                Label("Refresh Library", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13.5, weight: .semibold))
        }

        group("Storage") {
            Button {
                FadeInImage.cache.removeAllCachedResponses()
                cacheCleared = true
            } label: {
                Label(cacheCleared ? "Artwork Cache Cleared" : "Clear Artwork Cache",
                      systemImage: "trash")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13.5, weight: .semibold))
            .disabled(cacheCleared)
        }
    }

    // MARK: - Files

    @ViewBuilder
    private var files: some View {
        group("Network Share (SMB)") {
            VStack(alignment: .leading, spacing: 10) {
                if let saved = ShareStore.load() {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.connected.to.line.below.fill")
                            .foregroundStyle(.green)
                        Text("\(saved.username)@\(saved.server)/\(saved.share)")
                            .font(.system(size: 13, weight: .semibold).monospaced())
                        Spacer()
                        Button("Remove") {
                            UserDefaults.standard.removeObject(forKey: "savedShare")
                            smbServer = ""; smbShare = ""; smbUser = ""; smbPassword = ""
                            dismiss(); onSaved()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                field("Server", text: $smbServer, prompt: "192.168.1.10")
                field("Share", text: $smbShare, prompt: "media")
                field("Username", text: $smbUser, prompt: "user")
                HStack {
                    Text("Password").frame(width: 84, alignment: .leading)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    SecureField("••••••••", text: $smbPassword)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 24).padding(.vertical, 9)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(smbServer.isEmpty || smbShare.isEmpty || smbUser.isEmpty)
                Text("Files on the share appear in the Files tab and, without Plex, in the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Playback

    @ViewBuilder
    private var playback: some View {
        group("Intros & Ads") {
            labeledPicker("Skip mode", selection: $introSkipMode, options: [
                ("Off", "off"), ("Show button", "manual"), ("Automatic", "auto"),
            ])
            Text("Uses Plex intro/ad/credits markers. Automatic jumps past intros and ads for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        group("Seeking") {
            labeledPicker("Skip forward", selection: $skipForwardSecs, options: [
                ("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30),
                ("45 seconds", 45), ("60 seconds", 60), ("90 seconds", 90),
            ])
            labeledPicker("Skip back", selection: $skipBackSecs, options: [
                ("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30),
            ])
        }

        group("Episodes") {
            Toggle("Autoplay next episode", isOn: $autoPlayNext)
                .font(.system(size: 13.5))
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audio: some View {
        group("Output") {
            labeledPicker("Channels", selection: $audioOutput, options: [
                ("Auto", "auto"), ("Stereo (downmix)", "stereo"), ("5.1 Surround", "51"),
            ])
            Text("5.1 sends multichannel audio to HDMI or AirPlay receivers; Stereo downmixes everything for TV or headphone listening.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Dolby passthrough (HDMI receivers only)", isOn: $audioPassthrough)
                .font(.system(size: 13.5))
            Text("Bitstreams Dolby audio untouched to an HDMI receiver. ⚠️ On built-in speakers or headphones this mutes most movies — turn it off if you lose sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        group("Levels") {
            HStack {
                Text("Volume").font(.system(size: 13.5))
                CompatSlider(value: $defaultVolume, range: 0...130)
                    .tint(.white)
                Text("\(Int(defaultVolume))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Toggle("Volume boost", isOn: $volumeBoost)
                .font(.system(size: 13.5))
            Text("Evens out quiet dialogue and loud action scenes (dynamic range compression).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Languages

    @ViewBuilder
    private var languages: some View {
        group("Playback") {
            labeledPicker("Audio", selection: $langAudio, options: Self.trackLanguages)
            labeledPicker("Subtitles", selection: $langSubtitles, options: Self.trackLanguages)
            Text("Preferred track languages, picked automatically when a file has them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        group("Library") {
            labeledPicker("Metadata", selection: $langMetadata, options: Self.metaLanguages)
            labeledPicker("Artwork", selection: $langArtwork, options: Self.metaLanguages)
            Text("Language for titles, overviews and artwork fetched from TMDB. Plex items follow the Plex server's language settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bits

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.1)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func labeledPicker<T: Hashable>(_ label: String,
                                            selection: Binding<T>,
                                            options: [(String, T)]) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5))
            Spacer()
            Picker(label, selection: selection) {
                ForEach(options, id: \.1) { name, value in
                    Text(name).tag(value)
                }
            }
            .labelsHidden()
            #if !os(tvOS)
            .pickerStyle(.menu)
            #endif
            .fixedSize()
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
