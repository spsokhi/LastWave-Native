import Foundation

/// Liked songs and listening history, persisted as JSON in UserDefaults.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var liked: [Track] = [] { didSet { save(liked, "library.liked") } }
    @Published private(set) var recent: [Track] = [] { didSet { save(recent, "library.recent") } }

    private static let maxRecent = 100

    private init() {
        liked = load("library.liked")
        recent = load("library.recent")
    }

    func isLiked(_ track: Track) -> Bool {
        liked.contains { $0.videoId == track.videoId }
    }

    func toggleLike(_ track: Track) {
        if isLiked(track) {
            liked.removeAll { $0.videoId == track.videoId }
        } else {
            liked.insert(track, at: 0)
        }
    }

    func recordPlay(_ track: Track) {
        var updated = recent.filter { $0.videoId != track.videoId }
        updated.insert(track, at: 0)
        recent = Array(updated.prefix(Self.maxRecent))
    }

    func clearHistory() {
        recent = []
    }

    private func save(_ tracks: [Track], _ key: String) {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load(_ key: String) -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return tracks
    }
}
