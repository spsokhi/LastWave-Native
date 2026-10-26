import Foundation

/// A playable YouTube Music song. Mirrors `YouTubeMusicTrack` on Android.
struct Track: Codable, Identifiable, Hashable {
    let videoId: String
    var title: String
    var artist: String
    var album: String?
    var artworkURL: URL?
    var durationSeconds: Int?

    var id: String { videoId }

    var durationText: String? {
        guard let seconds = durationSeconds, seconds > 0 else { return nil }
        return formatTime(Double(seconds))
    }
}

/// A resolved, directly playable audio URL plus the headers YouTube expects
/// on the media request (the User-Agent must match the player client).
struct AudioStream {
    let url: URL
    let headers: [String: String]
    let expiresAt: Date
    let clientName: String
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
