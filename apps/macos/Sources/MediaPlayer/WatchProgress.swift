import Foundation

/// Local resume points keyed by share-relative path.
enum WatchProgress {
    private static let key = "watchProgress"

    private static var all: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func position(for path: String) -> Double? {
        all[path]
    }

    /// All saved resume points (path → seconds).
    static func allPositions() -> [String: Double] {
        all
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
}
