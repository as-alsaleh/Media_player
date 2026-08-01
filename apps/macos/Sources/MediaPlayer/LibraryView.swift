import SwiftUI

/// Movie/TV library backed by the streamer's SQLite index.
struct LibraryView: View {
    @ObservedObject var streamer: StreamerManager
    let onPlay: (URL, String) -> Void

    enum Tab: String, CaseIterable {
        case movies = "Movies"
        case shows = "TV Shows"
    }

    @State private var tab: Tab = .movies
    @State private var movies: [StreamerManager.LibraryMovie] = []
    @State private var episodes: [StreamerManager.LibraryEpisode] = []
    @State private var scanning = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: streamer.baseURL) { await load() }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer()
            if scanning {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(scanning)
            .help("Rescan the share")
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let status, movies.isEmpty && episodes.isEmpty {
            ContentUnavailableView(
                "Library", systemImage: "film.stack",
                description: Text(status))
        } else {
            switch tab {
            case .movies: movieList
            case .shows: showList
            }
        }
    }

    private var movieList: some View {
        List(movies) { movie in
            Button {
                play(path: movie.path, name: movie.title)
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: movie.poster_url.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                    .frame(width: 34, height: 51)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(movie.title).lineLimit(1)
                        HStack(spacing: 6) {
                            if let year = movie.year { Text(String(year)) }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(movie.size), countStyle: .file))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if WatchProgress.position(for: movie.path) != nil {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .help("Resume available")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(movie.overview ?? movie.title)
        }
        .listStyle(.sidebar)
    }

    private var showList: some View {
        List {
            ForEach(groupedShows, id: \.0) { show, eps in
                DisclosureGroup("\(show) (\(eps.count))") {
                    ForEach(eps) { ep in
                        Button {
                            play(path: ep.path, name: "\(show) S\(ep.season)E\(ep.episode)")
                        } label: {
                            HStack {
                                Text(String(format: "S%02dE%02d", ep.season, ep.episode))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if WatchProgress.position(for: ep.path) != nil {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var groupedShows: [(String, [StreamerManager.LibraryEpisode])] {
        Dictionary(grouping: episodes, by: \.show)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func play(path: String, name: String) {
        if let url = streamer.streamURL(path: path) {
            onPlay(url, name)
        }
    }

    private func load() async {
        guard streamer.baseURL != nil else { return }
        do {
            movies = try await streamer.libraryMovies()
            episodes = try await streamer.libraryEpisodes()
            status = movies.isEmpty && episodes.isEmpty
                ? "Empty — press ⟳ to scan the share" : nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        do {
            let result = try await streamer.scanLibrary()
            status = "Indexed \(result.movies) movies, \(result.episodes) episodes"
            await load()
        } catch {
            status = error.localizedDescription
        }
    }
}
