import Foundation

/// iOS-side connection to mediacore: starts the streamer *in-process* via the
/// UniFFI bridge (no helper processes on iOS), then talks the same local HTTP
/// API as the macOS app.
@MainActor
final class CoreClient: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastError: String?

    struct LibraryMovie: Codable, Identifiable, Hashable {
        let id: Int64
        let title: String
        let year: UInt16?
        let path: String
        let size: UInt64
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

    func connect(server: String, share: String, username: String, password: String) {
        lastError = nil
        let db = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.sqlite")
        try? FileManager.default.createDirectory(
            at: db.deletingLastPathComponent(), withIntermediateDirectories: true)

        Task.detached(priority: .userInitiated) {
            do {
                let url = try startStreamer(
                    server: server, share: share, username: username,
                    password: password, dbPath: db.path)
                await MainActor.run { [weak self] in self?.baseURL = URL(string: url) }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = String(describing: error)
                }
            }
        }
    }

    private func getJSON<T: Decodable>(_ pathComponent: String) async throws -> T {
        guard let baseURL else { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: baseURL.appendingPathComponent(pathComponent))
        request.timeoutInterval = 600
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func scanLibrary() async throws -> ScanResult { try await getJSON("library/scan") }
    func libraryMovies() async throws -> [LibraryMovie] { try await getJSON("library/movies") }
    func libraryEpisodes() async throws -> [LibraryEpisode] { try await getJSON("library/episodes") }

    func streamURL(path: String) -> URL? {
        guard let baseURL else { return nil }
        let escaped = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(baseURL.absoluteString)/stream/\(escaped)")
    }
}
