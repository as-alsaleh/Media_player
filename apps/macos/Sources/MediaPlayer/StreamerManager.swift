import Foundation

struct RemoteEntry: Codable, Identifiable, Hashable {
    let name: String
    let is_dir: Bool
    let size: UInt64
    var id: String { name }
}

/// Launches the bundled `mediacored` helper for a share and talks to its
/// localhost HTTP endpoints (/list, /stream).
@MainActor
final class StreamerManager: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastError: String?

    private var process: Process?

    static var helperURL: URL {
        // Contents/MacOS/mediacored next to the app binary.
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mediacored")
    }

    func start(config: ShareConfig, password: String) {
        stop()
        lastError = nil

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = Self.helperURL
        proc.arguments = [
            "--server", config.server,
            "--share", config.share,
            "--user", config.username,
            "--port", "0",
            "--db", support.appendingPathComponent("library.sqlite").path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["MEDIACORED_PASSWORD"] = password
        if let tmdbKey = UserDefaults.standard.string(forKey: "tmdbApiKey"), !tmdbKey.isEmpty {
            env["MEDIACORED_TMDB_KEY"] = tmdbKey
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
                    Task { @MainActor in self?.baseURL = url }
                    return
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.process == p else { return }
                self.baseURL = nil
                if p.terminationStatus != 0 {
                    self.lastError = "Streamer exited (status \(p.terminationStatus)) — check server/credentials"
                }
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        baseURL = nil
    }

    func list(path: String) async throws -> [RemoteEntry] {
        guard let baseURL else { throw URLError(.cannotConnectToHost) }
        var comps = URLComponents(url: baseURL.appendingPathComponent("list"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([RemoteEntry].self, from: data)
    }

    struct LibraryMovie: Codable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let year: UInt16?
        let path: String
        let size: UInt64
        let poster_url: String?
        let overview: String?
    }

    struct LibraryEpisode: Codable, Identifiable, Hashable {
        let id: Int64
        let show: String
        let season: UInt16
        let episode: UInt16
        let path: String
        let size: UInt64
    }

    struct ScanResult: Codable {
        let movies: Int
        let episodes: Int
    }

    private func getJSON<T: Decodable>(_ pathComponent: String) async throws -> T {
        guard let baseURL else { throw URLError(.cannotConnectToHost) }
        let url = baseURL.appendingPathComponent(pathComponent)
        var request = URLRequest(url: url)
        request.timeoutInterval = 600 // scans of large shares take a while
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func scanLibrary() async throws -> ScanResult {
        try await getJSON("library/scan")
    }

    func libraryMovies() async throws -> [LibraryMovie] {
        try await getJSON("library/movies")
    }

    func libraryEpisodes() async throws -> [LibraryEpisode] {
        try await getJSON("library/episodes")
    }

    func streamURL(path: String) -> URL? {
        guard let baseURL else { return nil }
        let escaped = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(baseURL.absoluteString)/stream/\(escaped)")
    }
}
