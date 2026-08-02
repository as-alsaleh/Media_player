import SwiftUI
import UniformTypeIdentifiers

@main
struct MediaPlayerApp: App {
    init() {
        // Running as a bare SwiftPM executable (no .app bundle) macOS treats
        // us as a background process; opt back into being a windowed app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @StateObject private var player = MPVPlayer()
    @StateObject private var streamer = StreamerManager()
    @State private var showPlayer = false
    @State private var nowPlaying = ""
    @State private var nowPlayingPath: String?
    @State private var refreshTick = 0
    @State private var markers: [StreamerManager.PlexMarker] = []
    @State private var controlsVisible = true
    @State private var hideWork: DispatchWorkItem?
    @State private var showSettingsBottom = false
    @State private var volumeLevel: Double = 100
    /// Hover position over the timeline: x in slider space, target time,
    /// and the slider's width (for clamping the bubble).
    @State private var hoverScrub: (x: CGFloat, time: Double, width: CGFloat)?
    @State private var previewInfo: StreamerManager.SeekPreviewInfo?

    private var hasPreviewImages: Bool {
        previewInfo?.trickplay != nil || previewInfo?.template != nil
    }

    private let progressTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if needsOnboarding {
                OnboardingView(streamer: streamer) {
                    refreshTick += 1
                    autoConnect()
                }
            } else {
                BrowseView(streamer: streamer, refreshTick: refreshTick,
                           onReconnect: autoConnect, onPlay: startPlayback)
            }

            // Player stays mounted so mpv's render surface survives; it is
            // just hidden while browsing.
            playerOverlay
                .opacity(showPlayer ? 1 : 0)
                .allowsHitTesting(showPlayer)
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear(perform: autoConnect)
        .onReceive(progressTimer) { _ in saveProgress() }
        .onChange(of: player.isPaused) { saveProgress() }
        .onChange(of: player.timePos) {
            // Automatic intro/ad skipping (credits keep their button so the
            // viewer can still watch them).
            guard showPlayer, Prefs.introSkipMode == "auto",
                  let marker = activeMarker, marker.kind != "credits" else { return }
            player.seek(to: marker.end_secs)
        }
        .preferredColorScheme(.dark)
    }

    /// First run: nothing configured yet — show the sign-in choices.
    private var needsOnboarding: Bool {
        _ = refreshTick  // re-evaluate after login
        let d = UserDefaults.standard
        let hasPlex = !(d.string(forKey: "plexToken") ?? "").isEmpty
        let hasJellyfin = !(d.string(forKey: "jellyfinUserToken") ?? "").isEmpty
        return !hasPlex && !hasJellyfin && ShareStore.load() == nil
    }

    /// Marker (intro/credits/commercial) covering the current position.
    private var activeMarker: StreamerManager.PlexMarker? {
        markers.first {
            player.timePos >= $0.start_secs && player.timePos < $0.end_secs - 1
        }
    }

    private func skipLabel(_ kind: String) -> String {
        switch kind {
        case "intro": return "Skip Intro"
        case "commercial": return "Skip Ad"
        case "credits": return "Skip Credits"
        default: return "Skip"
        }
    }

    private func pokeControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        NSCursor.unhide()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            // Stay visible while paused or while the cursor is parked on the
            // timeline (hover-scrubbing a preview).
            if !player.isPaused && hoverScrub == nil {
                withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func closePlayer() {
        if !player.isPaused { player.togglePause() }
        saveProgress()
        showPlayer = false
        refreshTick += 1  // re-pull library so Continue Watching updates
    }

    private var playerOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: player)
                .ignoresSafeArea()

            // A dead render backend otherwise looks like an endless black
            // screen — tell the user and give them a way out.
            if let err = player.initError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.yellow)
                    Text("Playback engine failed to start")
                        .font(.system(size: 16, weight: .semibold))
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Close") { closePlayer() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.25))
                }
                .padding(28)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }

            // Top gradient: back, title, codec badge.
            VStack {
                HStack(spacing: 12) {
                    Button(action: closePlayer) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Text(nowPlaying)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 30)
                .background(
                    LinearGradient(colors: [.black.opacity(0.65), .clear],
                                   startPoint: .top, endPoint: .bottom))
                Spacer()
            }
            .opacity(controlsVisible ? 1 : 0)

            // Skip marker / Next Episode button rides above the control bar.
            if let marker = activeMarker, Prefs.introSkipMode != "off" {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            if marker.kind == "credits", let next = NowPlaying.nextEpisode {
                                next()
                            } else {
                                player.seek(to: marker.end_secs)
                            }
                        } label: {
                            Text(marker.kind == "credits" && NowPlaying.nextEpisode != nil
                                 ? "Next Episode  ▶" : skipLabel(marker.kind))
                                .font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 28)
                        .padding(.bottom, controlsVisible ? 120 : 40)
                    }
                }
                .transition(.opacity)
            }

            // Bottom control bar.
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text(format(player.timePos))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        GeometryReader { geo in
                            Slider(
                                value: Binding(
                                    get: { player.timePos },
                                    set: { player.seek(to: $0) }
                                ),
                                in: 0...max(player.duration, 1)
                            )
                            .tint(progressRed)
                            .controlSize(.small)
                            // Intro/ad/credits marker ticks + hover cursor.
                            .background {
                                if player.duration > 0 {
                                    ForEach(markers, id: \.self) { m in
                                        Capsule()
                                            .fill(.white.opacity(0.55))
                                            .frame(width: 2.5, height: 9)
                                            .position(
                                                x: geo.size.width * m.start_secs / player.duration,
                                                y: geo.size.height / 2)
                                    }
                                    if let scrub = hoverScrub {
                                        Capsule()
                                            .fill(.white.opacity(0.8))
                                            .frame(width: 2, height: 10)
                                            .position(x: scrub.x, y: geo.size.height / 2)
                                    }
                                }
                            }
                            // Seek preview: track the hovered timestamp. The
                            // expanded content shape makes the whole strip
                            // around the timeline a hover target, not just
                            // the thin slider itself.
                            .contentShape(Rectangle().inset(by: -18))
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let pt):
                                    guard player.duration > 0, geo.size.width > 0 else { return }
                                    let frac = min(max(pt.x / geo.size.width, 0), 1)
                                    hoverScrub = (pt.x, frac * player.duration, geo.size.width)
                                case .ended:
                                    hoverScrub = nil
                                }
                            }
                            // The bubble itself, floating above the bar.
                            .overlay(alignment: .topLeading) {
                                if let scrub = hoverScrub {
                                    seekPreview(scrub)
                                }
                            }
                        }
                        .frame(height: 20)
                        Text(format(player.duration))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    ZStack {
                        HStack(spacing: 26) {
                            Button { player.seek(to: max(player.timePos - Double(Prefs.skipBackSecs), 0)) } label: {
                                Image(systemName: skipIcon(back: true)).font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                            Button { player.togglePause() } label: {
                                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 26))
                                    .frame(width: 52, height: 52)
                                    .background(.white.opacity(0.14), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.space, modifiers: [])
                            Button { player.seek(to: player.timePos + Double(Prefs.skipForwardSecs)) } label: {
                                Image(systemName: skipIcon(back: false)).font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 14) {
                            Spacer()
                            Image(systemName: volumeLevel <= 0 ? "speaker.slash.fill"
                                             : volumeLevel < 60 ? "speaker.wave.1.fill"
                                             : "speaker.wave.2.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 20)
                            Slider(value: Binding(
                                get: { volumeLevel },
                                set: { volumeLevel = $0; player.setDouble("volume", $0) }
                            ), in: 0...130)
                                .controlSize(.mini)
                                .tint(.white.opacity(0.7))
                                .frame(width: 90)
                            Button { showSettingsBottom = true } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Playback settings")
                            .popover(isPresented: $showSettingsBottom, arrowEdge: .top) {
                                PlayerSettingsView(player: player)
                            }
                            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Fullscreen (F)")
                        }
                    }
                    .foregroundStyle(.white)
                    .onAppear { volumeLevel = player.getDouble("volume") }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 40)
                .padding(.bottom, 22)
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)

            // Minimal progress line while controls are hidden.
            if !controlsVisible, player.duration > 0 {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.15))
                            Rectangle()
                                .fill(progressRed)
                                .frame(width: geo.size.width * min(player.timePos / player.duration, 1))
                        }
                    }
                    .frame(height: 3)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .background(playerShortcuts)
        .onContinuousHover { phase in
            if case .active = phase { pokeControls() }
        }
        .onAppear(perform: pokeControls)
        .onChange(of: player.isPaused) { if player.isPaused { pokeControls() } }
    }

    /// Compact YouTube-style tooltip hugging the timeline: mini frame
    /// preview (when available) plus the timestamp.
    @ViewBuilder
    private func seekPreview(_ scrub: (x: CGFloat, time: Double, width: CGFloat)) -> some View {
        let bubbleWidth: CGFloat = hasPreviewImages ? 148 : 56
        let x = min(max(scrub.x - bubbleWidth / 2, 0), scrub.width - bubbleWidth)
        VStack(spacing: 4) {
            if let tp = previewInfo?.trickplay {
                trickplayFrame(tp, time: scrub.time)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            } else if let template = previewInfo?.template {
                let ms = Int(scrub.time / 10) * 10_000
                FadeInImage(url: URL(string: template.replacingOccurrences(of: "{ms}", with: String(ms))))
                    .frame(width: 148, height: 83)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            }
            Text(format(scrub.time))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.75), in: Capsule())
        }
        .frame(width: bubbleWidth)
        .offset(x: x, y: hasPreviewImages ? -110 : -26)
        .allowsHitTesting(false)
    }

    /// One thumbnail cropped out of a Jellyfin trickplay tile-grid image.
    @ViewBuilder
    private func trickplayFrame(_ tp: StreamerManager.TrickplayInfo, time: Double) -> some View {
        let displayW: CGFloat = 148
        let scale = displayW / CGFloat(tp.thumb_width)
        let displayH = (CGFloat(tp.thumb_height) * scale).rounded()
        let idx = max(0, min(Int(time * 1000 / Double(max(tp.interval_ms, 1))),
                             Int(tp.thumbnail_count) - 1))
        let perGrid = Int(tp.tile_cols * tp.tile_rows)
        let grid = idx / max(perGrid, 1)
        let within = idx % max(perGrid, 1)
        let row = within / Int(max(tp.tile_cols, 1))
        let col = within % Int(max(tp.tile_cols, 1))
        FadeInImage(url: URL(string: tp.tile_url_template.replacingOccurrences(of: "{i}", with: String(grid))))
            .frame(width: displayW * CGFloat(tp.tile_cols),
                   height: displayH * CGFloat(tp.tile_rows),
                   alignment: .topLeading)
            .offset(x: -CGFloat(col) * displayW, y: -CGFloat(row) * displayH)
            .frame(width: displayW, height: displayH, alignment: .topLeading)
            .clipped()
    }

    /// SF Symbol matching the configured skip length.
    private func skipIcon(back: Bool) -> String {
        let secs = back ? Prefs.skipBackSecs : Prefs.skipForwardSecs
        let known = [5, 10, 15, 30, 45, 60, 75, 90].contains(secs) ? "\(secs)" : ""
        return back ? "gobackward.\(known.isEmpty ? "minus" : known)"
                    : "goforward.\(known.isEmpty ? "plus" : known)"
    }

    /// Hidden buttons that give the player standard keyboard control:
    /// ←/→ seek by the configured skip lengths, ↑/↓ volume, M mute,
    /// F fullscreen, Esc close.
    private var playerShortcuts: some View {
        Group {
            Button("") { player.seek(to: max(player.timePos - Double(Prefs.skipBackSecs), 0)); pokeControls() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { player.seek(to: player.timePos + Double(Prefs.skipForwardSecs)); pokeControls() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { player.adjustVolume(by: 5); pokeControls() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { player.adjustVolume(by: -5); pokeControls() }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { player.cycleMute() }
                .keyboardShortcut("m", modifiers: [])
            Button("") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
            Button("") { closePlayer() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func startPlayback(url: URL, title: String, path: String, resume: Double?) {
        saveProgress()
        nowPlaying = title
        nowPlayingPath = path
        showPlayer = true
        Prefs.apply(to: player)
        // mpv's own start option resumes reliably — including replaying the
        // same file, where waiting on a duration change never fires.
        player.setString("start", resume.map { String(format: "+%.1f", $0) } ?? "none")
        player.load(url: url)

        markers = []
        previewInfo = nil
        if path.hasPrefix("plex:") {
            let key = String(path.dropFirst("plex:".count))
            Task { markers = await streamer.plexMarkers(ratingKey: key) }
            Task { previewInfo = await streamer.seekPreview(ratingKey: key) }
            Task { await loadExternalSubtitles(ratingKey: key) }
        } else if path.hasPrefix("jf:") {
            let item = String(path.dropFirst("jf:".count))
            Task { previewInfo = await streamer.seekPreview(jellyfinItemId: item) }
        }

        player.onFileEnded = {
            if Prefs.autoPlayNext, let next = NowPlaying.nextEpisode {
                next()
            } else {
                closePlayer()
            }
        }
    }

    /// Attach Plex-managed external subtitles (sidecars, OpenSubtitles agent
    /// downloads) to the current file; auto-select one matching the
    /// preferred subtitle language.
    private func loadExternalSubtitles(ratingKey: String) async {
        let subs = await streamer.plexSubtitles(ratingKey: ratingKey)
        guard !subs.isEmpty else { return }
        // sub-add needs an open file — wait for the demuxer to come up.
        for _ in 0..<40 where player.duration <= 0 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let pref = Prefs.langSubtitles.split(separator: ",").map(String.init)
        var selected = false
        for sub in subs {
            let matches = !pref.isEmpty && (sub.lang.map { lang in
                pref.contains { lang.hasPrefix($0) || $0.hasPrefix(lang) }
            } ?? false)
            player.addSubtitle(url: sub.url, title: sub.title, lang: sub.lang,
                               select: matches && !selected)
            if matches { selected = true }
        }
    }

    private func saveProgress() {
        guard let path = nowPlayingPath, player.duration > 0 else { return }
        WatchProgress.save(path: path, position: player.timePos, duration: player.duration)
        // Mirror progress to the source server so watch history stays in sync.
        if path.hasPrefix("plex:") {
            streamer.reportPlexProgress(
                ratingKey: String(path.dropFirst("plex:".count)),
                time: player.timePos,
                duration: player.duration,
                state: player.isPaused ? "paused" : "playing")
        } else if path.hasPrefix("jf:") {
            streamer.reportJellyfinProgress(
                itemId: String(path.dropFirst("jf:".count)),
                time: player.timePos,
                state: player.isPaused ? "paused" : "playing")
        }
    }

    private func autoConnect() {
        if let config = ShareStore.load(),
           let password = ShareStore.password(for: config) {
            streamer.start(config: config, password: password)
        } else {
            // Plex-only (or onboarding): engine still hosts the login flow.
            streamer.startPlexOnly()
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
