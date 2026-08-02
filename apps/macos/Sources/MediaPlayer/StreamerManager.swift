import Foundation

struct RemoteEntry: Codable, Identifiable, Hashable {
    let name: String
    let is_dir: Bool
    let size: UInt64
    var id: String { name }
}

/// Fronts the mediacore streamer's localhost HTTP API.
/// On macOS it launches the bundled `mediacored` helper; on iOS/tvOS the
/// streamer runs in-process (UniFFI) and its URL is adopted via `adopt`.
@MainActor
final class StreamerManager: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastError: String?

    /// iOS/tvOS: point at the in-process streamer.
    func adopt(baseURL url: URL?, error: String? = nil) {
        baseURL = url
        lastError = error
    }

    #if os(macOS)
    private var process: Process?
    private var lastConfig: ShareConfig??
    private var lastPassword: String??
    private var restartAttempts = 0

    static var helperURL: URL {
        // Contents/MacOS/mediacored next to the app binary.
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mediacored")
    }

    /// Start without a file share — Plex-only mode (also used for onboarding
    /// so the login endpoints are reachable before anything is configured).
    func startPlexOnly() {
        start(config: nil, password: nil)
    }

    func start(config: ShareConfig, password: String) {
        start(config: Optional(config), password: Optional(password))
    }

    private func start(config: ShareConfig?, password: String?) {
        stop()
        lastError = nil
        lastConfig = config
        lastPassword = password

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = Self.helperURL
        proc.arguments = [
            "--port", "0",
            "--db", support.appendingPathComponent("library.sqlite").path,
        ]
        var env = ProcessInfo.processInfo.environment
        if let config, let password {
            proc.arguments?.append(contentsOf: [
                "--server", config.server,
                "--share", config.share,
                "--user", config.username,
            ])
            env["MEDIACORED_PASSWORD"] = password
        }
        if let tmdbKey = UserDefaults.standard.string(forKey: "tmdbApiKey"), !tmdbKey.isEmpty {
            env["MEDIACORED_TMDB_KEY"] = tmdbKey
        }
        if let plexURL = UserDefaults.standard.string(forKey: "plexServerURL"), !plexURL.isEmpty,
           let adminToken = UserDefaults.standard.string(forKey: "plexToken"), !adminToken.isEmpty {
            proc.arguments?.append(contentsOf: ["--plex-url", plexURL])
            // Active token may be a Home user's; admin token drives switching.
            let active = UserDefaults.standard.string(forKey: "plexActiveToken") ?? adminToken
            env["MEDIACORED_PLEX_TOKEN"] = active
            env["MEDIACORED_PLEX_ADMIN_TOKEN"] = adminToken
        }
        if let jfURL = UserDefaults.standard.string(forKey: "jellyfinURL"), !jfURL.isEmpty,
           let jfKey = UserDefaults.standard.string(forKey: "jellyfinApiKey"), !jfKey.isEmpty {
            proc.arguments?.append(contentsOf: ["--jellyfin-url", jfURL])
            env["MEDIACORED_JELLYFIN_KEY"] = jfKey
            if let token = UserDefaults.standard.string(forKey: "jellyfinUserToken"), !token.isEmpty,
               let userId = UserDefaults.standard.string(forKey: "jellyfinUserId"), !userId.isEmpty {
                env["MEDIACORED_JELLYFIN_USER_TOKEN"] = token
                env["MEDIACORED_JELLYFIN_USER_ID"] = userId
            }
        }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastError = "Failed to launch streamer: \(error.localizedDescription)"
            return
        }
        process = proc

        // Read lines until the LISTEN line appears.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if line.hasPrefix("LISTEN "),
                   let url = URL(string: String(line.dropFirst("LISTEN ".count))) {
                    handle.readabilityHandler = nil
                    Task { @MainActor in
                        self?.baseURL = url
                        self?.restartAttempts = 0
                    }
                    return
                }
            }
        }

        // Watchdog: if the helper never reports LISTEN, kill and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.process == proc, self.baseURL == nil else { return }
            proc.terminate()
            self.attemptRestart(reason: "engine start timed out")
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.process == p else { return }
                self.baseURL = nil
                self.attemptRestart(
                    reason: "engine exited (status \(p.terminationStatus))")
            }
        }
    }

    /// Restart with backoff after an unexpected helper death.
    private func attemptRestart(reason: String) {
        guard let config = lastConfig, let password = lastPassword else { return }
        // Double-optionals: outer = "have we started before", inner = mode.
        guard restartAttempts < 3 else {
            lastError = "\(reason) — gave up after 3 retries. Check the server and Settings."
            return
        }
        restartAttempts += 1
        lastError = "\(reason) — reconnecting (attempt \(restartAttempts))…"
        let delay = Double(restartAttempts) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.baseURL == nil else { return }
            let attempts = self.restartAttempts
            self.start(config: config, password: password)  // preserves mode
            self.restartAttempts = attempts
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        baseURL = nil
    }
    #endif

    func list(path: String) async throws -> [RemoteEntry] {
        guard let baseURL else { throw URLError(.cannotConnectToHost) }
        var comps = URLComponents(url: baseURL.appendingPathComponent("list"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([RemoteEntry].self, from: data)
    }

    struct LibraryMovie: Codable, Identifiable, Hashable {
        let uid: String
        let title: String
        let year: UInt16?
        let poster_url: String?
        let backdrop_url: String?
        let overview: String?
        let stream_url: String
        let progress_key: String
        let source: String
        let view_offset_secs: Double?
        let watched: Bool
        let last_viewed_at: UInt64?
        let duration_secs: Double?
        let tmdb_id: UInt64?
        let added_at: UInt64?
        /// 0–10 (Rotten Tomatoes critic score on most Plex servers).
        let critic_rating: Double?
        let audience_rating: Double?
        var id: String { uid }
    }

    struct LibraryShow: Codable, Identifiable, Hashable {
        let uid: String
        let name: String
        let episode_count: UInt32
        let poster_url: String?
        let backdrop_url: String?
        let overview: String?
        let source: String
        let added_at: UInt64?
        let critic_rating: Double?
        let audience_rating: Double?
        var id: String { uid }
    }

    struct LibraryEpisode: Codable, Identifiable, Hashable {
        let uid: String
        let show: String
        let season: UInt16
        let episode: UInt16
        let title: String?
        let thumb_url: String?
        let overview: String?
        let stream_url: String
        let progress_key: String
        let source: String
        let view_offset_secs: Double?
        let watched: Bool
        let last_viewed_at: UInt64?
        let duration_secs: Double?
        let show_tmdb_id: UInt64?
        var id: String { uid }
    }

    struct PlexUser: Codable, Identifiable, Hashable {
        let uuid: String
        let title: String
        let protected: Bool
        var id: String { uuid }
    }

    func plexUsers() async throws -> [PlexUser] {
        try await getJSON("plex/users")
    }

    /// Switch Plex Home user; stores the user token and restarts the helper.
    func switchPlexUser(uuid: String, pin: String?) async -> Bool {
        guard let baseURL else { return false }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/switch"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "uuid", value: uuid)]
        if let pin, !pin.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "pin", value: pin))
        }
        guard let (data, resp) = try? await URLSession.shared.data(from: comps.url!),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = obj["token"]
        else { return false }

        UserDefaults.standard.set(token, forKey: "plexActiveToken")
        #if os(macOS)
        if let config = ShareStore.load(), let password = ShareStore.password(for: config) {
            start(config: config, password: password)
        }
        #else
        onUserSwitched?()
        #endif
        return true
    }

    /// iOS/tvOS hook: restart the in-process streamer after a user switch.
    var onUserSwitched: (() -> Void)?

    struct PlexPin: Codable {
        let id: UInt64
        let code: String
        let auth_url: String
    }

    struct PlexLoginResult: Codable {
        let pending: Bool
        let server_name: String?
        let server_url: String?
        let token: String?
    }

    func plexLoginStart() async -> PlexPin? {
        guard let baseURL else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(
            from: baseURL.appendingPathComponent("plex/login/start")) else { return nil }
        return try? JSONDecoder().decode(PlexPin.self, from: data)
    }

    func plexLoginPoll(id: UInt64) async -> PlexLoginResult? {
        guard let baseURL else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/login/poll"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: String(id))]
        guard let (data, resp) = try? await URLSession.shared.data(from: comps.url!),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(PlexLoginResult.self, from: data)
    }

    struct JellyfinUser: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let has_password: Bool
    }

    struct JellyfinLogin: Codable {
        let token: String
        let user_id: String
        let name: String
    }

    /// Users on a Jellyfin server's login screen.
    func jellyfinUsers(base: String) async -> [JellyfinUser] {
        guard let baseURL else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("jellyfin/users"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "base", value: base)]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return [] }
        return (try? JSONDecoder().decode([JellyfinUser].self, from: data)) ?? []
    }

    func jellyfinLogin(base: String, username: String, password: String) async -> JellyfinLogin? {
        guard let baseURL else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("jellyfin/login"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        guard let (data, resp) = try? await URLSession.shared.data(from: comps.url!),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(JellyfinLogin.self, from: data)
    }

    /// Fire-and-forget playback state to Jellyfin ("playing"|"paused"|"stopped").
    func reportJellyfinProgress(itemId: String, time: Double, state: String) {
        fireAndForget("jellyfin/progress", [
            URLQueryItem(name: "item_id", value: itemId),
            URLQueryItem(name: "time", value: String(time)),
            URLQueryItem(name: "state", value: state),
        ])
    }

    func jellyfinSetWatched(itemId: String, watched: Bool) {
        fireAndForget("jellyfin/watched", [
            URLQueryItem(name: "item_id", value: itemId),
            URLQueryItem(name: "watched", value: watched ? "true" : "false"),
        ])
    }

    /// Jellyfin trickplay tile manifest for the seek-preview bubble.
    struct TrickplayInfo: Codable, Equatable {
        let tile_url_template: String   // contains "{i}"
        let interval_ms: UInt64
        let tile_cols: UInt32
        let tile_rows: UInt32
        let thumb_width: UInt32
        let thumb_height: UInt32
        let thumbnail_count: UInt32
    }

    struct SeekPreviewInfo: Codable, Equatable {
        let trickplay: TrickplayInfo?
        /// Plex BIF frame-URL template ("{ms}" placeholder), fallback.
        let template: String?
    }

    /// Seek-preview sources for an item (Jellyfin trickplay, else Plex BIF).
    /// Pass a Plex rating key or a Jellyfin item id.
    func seekPreview(ratingKey: String? = nil, jellyfinItemId: String? = nil) async -> SeekPreviewInfo? {
        guard let baseURL else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/preview"), resolvingAgainstBaseURL: false)!
        if let jellyfinItemId {
            comps.queryItems = [URLQueryItem(name: "item_id", value: jellyfinItemId)]
        } else {
            comps.queryItems = [URLQueryItem(name: "rating_key", value: ratingKey)]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return nil }
        return try? JSONDecoder().decode(SeekPreviewInfo.self, from: data)
    }

    struct PlexSubtitle: Codable, Hashable {
        let url: String
        let lang: String?
        let title: String?
        let codec: String?
    }

    /// External subtitles Plex manages for an item (sidecar files and
    /// agent downloads such as OpenSubtitles).
    func plexSubtitles(ratingKey: String) async -> [PlexSubtitle] {
        guard let baseURL else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/subtitles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "rating_key", value: ratingKey)]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return [] }
        return (try? JSONDecoder().decode([PlexSubtitle].self, from: data)) ?? []
    }

    struct PlexMarker: Codable, Hashable {
        let kind: String     // "intro" | "credits" | "commercial"
        let start_secs: Double
        let end_secs: Double
    }

    func plexMarkers(ratingKey: String) async -> [PlexMarker] {
        guard let baseURL else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/markers"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "rating_key", value: ratingKey)]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return [] }
        return (try? JSONDecoder().decode([PlexMarker].self, from: data)) ?? []
    }

    func plexRate(ratingKey: String, rating: Double) {
        fireAndForget("plex/rate", [
            URLQueryItem(name: "rating_key", value: ratingKey),
            URLQueryItem(name: "rating", value: String(rating)),
        ])
    }

    /// Jellyfin parity — same shapes as the Plex calls, keyed by item id.
    func jellyfinMarkers(itemId: String) async -> [PlexMarker] {
        guard let baseURL else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("jellyfin/markers"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "item_id", value: itemId)]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return [] }
        return (try? JSONDecoder().decode([PlexMarker].self, from: data)) ?? []
    }

    func jellyfinSubtitles(itemId: String) async -> [PlexSubtitle] {
        guard let baseURL else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("jellyfin/subtitles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "item_id", value: itemId)]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!) else { return [] }
        return (try? JSONDecoder().decode([PlexSubtitle].self, from: data)) ?? []
    }

    func jellyfinRate(itemId: String, rating: Double) {
        fireAndForget("jellyfin/rate", [
            URLQueryItem(name: "item_id", value: itemId),
            URLQueryItem(name: "rating", value: String(rating)),
        ])
    }

    func plexSetWatched(ratingKey: String, watched: Bool) {
        fireAndForget("plex/watched", [
            URLQueryItem(name: "rating_key", value: ratingKey),
            URLQueryItem(name: "watched", value: watched ? "true" : "false"),
        ])
    }

    // MARK: - Offline downloads

    struct DownloadEntry: Codable, Identifiable, Hashable {
        let key: String
        let title: String
        let poster_url: String?
        let file: String
        /// Local poster copy — artwork with no server reachable.
        let poster_file: String?
        let bytes_done: UInt64
        let bytes_total: UInt64?
        let state: String   // "downloading" | "done" | "error"
        var id: String { key }

        var posterURL: URL? {
            if let poster_file { return URL(fileURLWithPath: poster_file) }
            return poster_url.flatMap(URL.init)
        }

        var fraction: Double? {
            guard let total = bytes_total, total > 0 else { return nil }
            return Double(bytes_done) / Double(total)
        }
    }

    func downloadsList() async -> [DownloadEntry] {
        guard let baseURL else { return [] }
        let url = baseURL.appendingPathComponent("downloads/list")
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return (try? JSONDecoder().decode([DownloadEntry].self, from: data)) ?? []
    }

    func startDownload(key: String, url: String, title: String, poster: String?) {
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "title", value: title),
        ]
        if let poster { items.append(URLQueryItem(name: "poster", value: poster)) }
        fireAndForget("downloads/start", items)
    }

    func deleteDownload(key: String) {
        fireAndForget("downloads/delete", [URLQueryItem(name: "key", value: key)])
    }

    private func fireAndForget(_ path: String, _ items: [URLQueryItem]) {
        guard let baseURL else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        URLSession.shared.dataTask(with: comps.url!).resume()
    }

    func reportPlexProgress(ratingKey: String, time: Double, duration: Double, state: String) {
        guard let baseURL else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("plex/progress"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "rating_key", value: ratingKey),
            URLQueryItem(name: "time", value: String(Int(time))),
            URLQueryItem(name: "duration", value: String(Int(duration))),
            URLQueryItem(name: "state", value: state),
        ]
        URLSession.shared.dataTask(with: comps.url!).resume()
    }

    /// Resolve a (possibly relative) stream URL against the helper's base.
    func resolveStream(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        guard let baseURL else { return nil }
        return URL(string: baseURL.absoluteString + raw)
    }

    struct ScanResult: Codable {
        let movies: Int
        let episodes: Int
    }

    private func getJSON<T: Decodable>(_ pathComponent: String,
                                       query: [URLQueryItem] = []) async throws -> T {
        guard let baseURL else { throw URLError(.cannotConnectToHost) }
        var comps = URLComponents(url: baseURL.appendingPathComponent(pathComponent),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 600 // scans of large shares take a while
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func scanLibrary() async throws -> ScanResult {
        let lang = UserDefaults.standard.string(forKey: "langMetadata") ?? ""
        return try await getJSON("library/scan",
                                 query: lang.isEmpty ? [] : [URLQueryItem(name: "lang", value: lang)])
    }

    func libraryMovies() async throws -> [LibraryMovie] {
        try await getJSON("library/movies")
    }

    func libraryEpisodes() async throws -> [LibraryEpisode] {
        try await getJSON("library/episodes")
    }

    func libraryShows() async throws -> [LibraryShow] {
        try await getJSON("library/shows")
    }

    func streamURL(path: String) -> URL? {
        guard let baseURL else { return nil }
        let escaped = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(baseURL.absoluteString)/stream/\(escaped)")
    }
}
