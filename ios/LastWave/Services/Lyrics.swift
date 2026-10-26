import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

struct Lyrics {
    let synced: [LyricLine]
    let plain: String?

    var isEmpty: Bool { synced.isEmpty && (plain?.isEmpty ?? true) }

    /// Index of the line being sung at `time`, or nil before the first line.
    func activeIndex(at time: Double) -> Int? {
        var low = 0
        var high = synced.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if synced[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Synced lyrics from LRCLIB (https://lrclib.net), the same primary source as
/// `LrclibLyricsApi.kt` on Android.
enum LyricsService {
    private static let userAgent = "LastWave-iOS/0.1 (https://github.com/Clash-Projects/LastWave-Native)"

    static func fetch(for track: Track) async -> Lyrics? {
        let title = cleanTitle(track.title)
        let artist = cleanArtist(track.artist)

        var getItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album = track.album { getItems.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = track.durationSeconds { getItems.append(URLQueryItem(name: "duration", value: String(duration))) }
        if let entry = await request("https://lrclib.net/api/get", getItems) as? JSONObject,
           let lyrics = parse(entry), !lyrics.isEmpty {
            return lyrics
        }

        let searchItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let results = await request("https://lrclib.net/api/search", searchItems) as? [Any] else { return nil }
        let entries = results.compactMap { $0 as? JSONObject }
        let best = entries.first { $0.str("syncedLyrics")?.isEmpty == false } ?? entries.first
        return best.flatMap(parse)
    }

    private static func request(_ base: String, _ items: [URLQueryItem]) async -> Any? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0)
    }

    private static func parse(_ entry: JSONObject) -> Lyrics? {
        let synced = parseLRC(entry.str("syncedLyrics") ?? "")
        let plain = entry.str("plainLyrics")
        if synced.isEmpty && (plain?.isEmpty ?? true) { return nil }
        return Lyrics(synced: synced, plain: plain)
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]") else { return [] }
        var lines: [(Double, String)] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard let last = matches.last, let lastRange = Range(last.range, in: rawLine) else { continue }
            let text = rawLine[lastRange.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minRange = Range(match.range(at: 1), in: rawLine),
                      let secRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minRange]),
                      let seconds = Double(rawLine[secRange]) else { continue }
                lines.append((minutes * 60 + seconds, text))
            }
        }
        return lines.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// Strips YouTube decorations such as "(Official Video)" or "[Lyrics]".
    static func cleanTitle(_ title: String) -> String {
        var result = title
        let patterns = [
            "\\s*[\\(\\[][^\\)\\]]*(official|video|audio|lyric|visualizer|remaster|hd|4k|mv)[^\\)\\]]*[\\)\\]]",
            "\\s*-\\s*topic$",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func cleanArtist(_ artist: String) -> String {
        var result = artist
        if result.hasSuffix(" - Topic") { result = String(result.dropLast(8)) }
        for separator in [" & ", ", ", " feat. ", " ft. ", " x "] {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
