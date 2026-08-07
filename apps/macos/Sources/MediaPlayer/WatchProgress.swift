import Foundation

/// Local resume points keyed by share-relative path, scoped per active
/// Plex Home user so profiles never see each other's history.
enum WatchProgress {
    private static var key: String {
        let user = UserDefaults.standard.string(forKey: "plexActiveUserName") ?? ""
        return user.isEmpty ? "watchProgress" : "watchProgress:\(user)"
    }

    private static var all: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func position(for path: String) -> Double? {
        all[path]
    }

    static func save(path: String, position: Double, duration: Double) {
        guard duration > 0 else { return }
        var dict = all
        if position / duration > 0.95 || position < 30 {
            dict.removeValue(forKey: path) // finished or barely started
        } else {
            dict[path] = position
        }
        all = dict
    }

    /// All saved resume points (path → seconds) for the active user.
    static func allPositions() -> [String: Double] {
        all
    }

    /// Seed a resume point from a server-side source (e.g. Plex viewOffset)
    /// without the finished/barely-started pruning.
    static func seed(path: String, position: Double) {
        var dict = all
        dict[path] = position
        all = dict
    }

    /// Drop the local resume point (Remove from Continue Watching).
    static func clear(path: String) {
        var dict = all
        dict.removeValue(forKey: path)
        all = dict
    }
}
