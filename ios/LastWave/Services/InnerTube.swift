import Foundation

enum InnerTubeError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case noAudio
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube Music returned HTTP \(code)"
        case .unplayable(let reason): return reason
        case .noAudio: return "No playable audio stream was found for this song"
        case .badResponse: return "Unexpected response from YouTube Music"
        }
    }
}

/// Client for the private InnerTube endpoints used by music.youtube.com.
/// Port of the relevant parts of `InnerTubeMusicApi.kt`: search and radio use
/// WEB_REMIX; playback uses the no-cipher VISIONOS / ANDROID_VR clients, which
/// return direct AAC (itag 140) URLs that AVPlayer can stream natively.
actor InnerTube {
    static let shared = InnerTube()

    private struct WebConfig {
        let apiKey: String
        let clientVersion: String
        let visitorData: String?
    }

    struct PlayerClient {
        let name: String
        let version: String
        let id: String
        let userAgent: String
        let extra: [String: String]
    }

    static let musicAPI = "https://music.youtube.com/youtubei/v1"
    static let youtubeAPI = "https://www.youtube.com/youtubei/v1"
    static let musicOrigin = "https://music.youtube.com"
    static let youtubeOrigin = "https://www.youtube.com"
    static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    static let fallbackKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    static let fallbackVersion = "1.20261020.10.00"
    static let songsSearchFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    static let consentCookie = "SOCS=CAESEwgDEgk2ODE4NDk5NzAaAmVuIAEaBgiA_LyaBg; CONSENT=YES+cb.20210328-17-p0.en+FX+999"

    /// Same order as DIRECT_FAST_CLIENT_ORDER on Android, plus IOS whose
    /// HLS manifest AVPlayer can play as a last resort.
    static let playerClients: [PlayerClient] = [
        PlayerClient(
            name: "VISIONOS", version: "0.1", id: "101",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            extra: ["osName": "visionOS", "osVersion": "1.3.21O771", "deviceMake": "Apple", "deviceModel": "RealityDevice14,1"]
        ),
        PlayerClient(
            name: "ANDROID_VR", version: "1.65.10", id: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extra: ["osName": "Android", "osVersion": "12", "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": "32"]
        ),
        PlayerClient(
            name: "IOS", version: "21.26.4", id: "5",
            userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2;)",
            extra: ["osName": "iPhone", "osVersion": "18.3.2.22D82", "deviceMake": "Apple", "deviceModel": "iPhone16,2"]
        ),
    ]

    private static let unavailableReasons = [
        "video has been removed", "video has been deleted", "this video is private",
        "this is a private video", "not available in your country", "blocked in your country",
        "copyright claim",
    ]

    private let session: URLSession
    private var config: WebConfig?
    private var lastConfigAttempt = Date.distantPast
    private var streamCache: [String: AudioStream] = [:]
    private var lastGoodClient: String?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    // MARK: - Locale

    private var hl: String { Locale.current.language.languageCode?.identifier ?? "en" }
    private var gl: String { Locale.current.region?.identifier ?? "US" }

    // MARK: - Web config

    private func getConfig() async -> WebConfig {
        if let config, config.visitorData != nil { return config }
        if let config, Date().timeIntervalSince(lastConfigAttempt) < 30 { return config }
        lastConfigAttempt = Date()

        var request = URLRequest(url: URL(string: "\(Self.musicOrigin)/")!, timeoutInterval: 8)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.consentCookie, forHTTPHeaderField: "Cookie")

        var fetched = WebConfig(apiKey: Self.fallbackKey, clientVersion: Self.fallbackVersion, visitorData: nil)
        if let result = try? await session.data(for: request),
           let status = (result.1 as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
           let html = String(data: result.0, encoding: .utf8) {
            fetched = WebConfig(
                apiKey: Self.findConfig(html, "INNERTUBE_API_KEY") ?? Self.fallbackKey,
                clientVersion: Self.findConfig(html, "INNERTUBE_CONTEXT_CLIENT_VERSION") ?? Self.fallbackVersion,
                visitorData: Self.findConfig(html, "VISITOR_DATA") ?? Self.findConfig(html, "EOM_VISITOR_DATA")
            )
        }
        config = fetched
        return fetched
    }

    private static func findConfig(_ html: String, _ key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\x3d", with: "=")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: - HTTP

    private func post(_ url: String, body: JSONObject, headers: [String: String], timeout: TimeInterval = 10) async throws -> JSONObject {
        guard let endpoint = URL(string: url) else { throw InnerTubeError.badResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(hl)-\(gl),\(hl);q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 400 || status == 403 || status == 429 { config = nil }
            throw InnerTubeError.http(status)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw InnerTubeError.badResponse
        }
        return root
    }

    /// POST to music.youtube.com as the WEB_REMIX client.
    private func webRemix(_ endpoint: String, _ payload: JSONObject) async throws -> JSONObject {
        let config = await getConfig()
        var client: JSONObject = [
            "clientName": "WEB_REMIX",
            "clientVersion": config.clientVersion,
            "hl": hl,
            "gl": gl,
        ]
        if let visitor = config.visitorData { client["visitorData"] = visitor }
        var body = payload
        body["context"] = ["client": client]

        var headers = [
            "User-Agent": Self.webUserAgent,
            "Origin": Self.musicOrigin,
            "X-Origin": Self.musicOrigin,
            "Referer": "\(Self.musicOrigin)/",
            "X-Goog-Api-Format-Version": "1",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": config.clientVersion,
        ]
        if let visitor = config.visitorData { headers["X-Goog-Visitor-Id"] = visitor }
        return try await post("\(Self.musicAPI)/\(endpoint)?key=\(config.apiKey)&prettyPrint=false", body: body, headers: headers)
    }

    // MARK: - Search & radio

    func searchSongs(_ query: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var results: [Track] = []
        if let root = try? await webRemix("search", ["query": trimmed, "params": Self.songsSearchFilter]) {
            results = Self.parseSongs(root)
        }
        if results.isEmpty {
            // Unfiltered search only when the songs-filtered one came back empty.
            let root = try await webRemix("search", ["query": trimmed])
            results = Self.parseSongs(root)
        }
        return results
    }

    /// YouTube Music's own radio for a seed song (`RDAMVM<videoId>`).
    func radio(for videoId: String) async throws -> [Track] {
        let root = try await webRemix("next", [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "params": "wAEB",
            "isAudioOnly": true,
        ])
        return Self.parseSongs(root).filter { $0.videoId != videoId }
    }

    // MARK: - Stream resolution

    func invalidate(_ videoId: String) {
        streamCache[videoId] = nil
    }

    func resolveStream(_ videoId: String) async throws -> AudioStream {
        if let cached = streamCache[videoId], cached.expiresAt.timeIntervalSinceNow > 120 {
            return cached
        }
        let config = await getConfig()
        var clients = Self.playerClients
        if let good = lastGoodClient, let index = clients.firstIndex(where: { $0.name == good }), index > 0 {
            clients.insert(clients.remove(at: index), at: 0)
        }

        var lastError: Error = InnerTubeError.noAudio
        for client in clients {
            do {
                let stream = try await resolve(videoId, client: client, visitorData: config.visitorData)
                lastGoodClient = client.name
                streamCache[videoId] = stream
                return stream
            } catch InnerTubeError.unplayable(let reason) {
                let lower = reason.lowercased()
                if Self.unavailableReasons.contains(where: { lower.contains($0) }) {
                    throw InnerTubeError.unplayable(reason)
                }
                lastError = InnerTubeError.unplayable(reason)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func resolve(_ videoId: String, client: PlayerClient, visitorData: String?) async throws -> AudioStream {
        var clientContext: JSONObject = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData { clientContext["visitorData"] = visitorData }
        for (key, value) in client.extra { clientContext[key] = value }

        let body: JSONObject = [
            "context": ["client": clientContext],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var headers = [
            "User-Agent": client.userAgent,
            "X-YouTube-Client-Name": client.id,
            "X-YouTube-Client-Version": client.version,
            "Origin": Self.youtubeOrigin,
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }

        let root = try await post("\(Self.youtubeAPI)/player?prettyPrint=false", body: body, headers: headers, timeout: 8)
        let status = root.obj("playabilityStatus")
        guard status?.str("status") == "OK" else {
            throw InnerTubeError.unplayable(status?.str("reason") ?? "This song can't be played (\(status?.str("status") ?? "unknown"))")
        }
        guard let streaming = root.obj("streamingData") else { throw InnerTubeError.noAudio }

        var mediaHeaders = ["User-Agent": client.userAgent]
        if let visitorData { mediaHeaders["X-Goog-Visitor-Id"] = visitorData }
        let responseExpiry = streaming.str("expiresInSeconds").flatMap { Double($0) }.map { Date().addingTimeInterval($0) }
            ?? Date().addingTimeInterval(5 * 60)

        // AVPlayer can't decode WebM/Opus, so only AAC in MP4 is usable.
        // The IOS client only serves bounded ranges on direct URLs; use its HLS instead.
        if client.name != "IOS" {
            let audio = (streaming.arr("adaptiveFormats") ?? [])
                .compactMap { $0 as? JSONObject }
                .filter { ($0.str("mimeType") ?? "").hasPrefix("audio/mp4") && $0.str("url") != nil }
                .sorted { lhs, rhs in
                    let lhsPreferred = lhs.int("itag") == 140
                    let rhsPreferred = rhs.int("itag") == 140
                    if lhsPreferred != rhsPreferred { return lhsPreferred }
                    return (lhs.int("bitrate") ?? 0) > (rhs.int("bitrate") ?? 0)
                }
            if let best = audio.first, let raw = best.str("url"), let url = URL(string: raw) {
                return AudioStream(url: url, headers: mediaHeaders, expiresAt: Self.expiry(of: url) ?? responseExpiry, clientName: client.name)
            }
        }
        if let hls = streaming.str("hlsManifestUrl"), let url = URL(string: hls) {
            return AudioStream(url: url, headers: mediaHeaders, expiresAt: responseExpiry, clientName: client.name)
        }
        throw InnerTubeError.noAudio
    }

    private static func expiry(of url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "expire" })?.value,
              let seconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Parsing

    static func parseSongs(_ root: JSONObject) -> [Track] {
        var songs: [Track] = []
        songs += JSONWalk.collect(root, key: "musicResponsiveListItemRenderer").compactMap(parseListItem)
        songs += JSONWalk.collect(root, key: "playlistPanelVideoRenderer").compactMap(parsePanelItem)
        if songs.isEmpty {
            songs += JSONWalk.collect(root, key: "videoRenderer").compactMap(parseVideoRenderer)
        }
        var seen = Set<String>()
        return songs.filter { !$0.videoId.isEmpty && seen.insert($0.videoId).inserted }
    }

    private static func parseListItem(_ renderer: JSONObject) -> Track? {
        guard let videoId = renderer.obj("playlistItemData")?.str("videoId")
                ?? JSONWalk.firstString(renderer.obj("overlay") ?? [:], key: "videoId")
                ?? JSONWalk.firstString(renderer.arr("flexColumns") ?? [], key: "videoId")
        else { return nil }

        let columns = (renderer.arr("flexColumns") ?? []).compactMap {
            ($0 as? JSONObject)?.obj("musicResponsiveListItemFlexColumnRenderer")?.obj("text")
        }
        guard let titleNode = columns.first else { return nil }
        let title = runsText(titleNode)
        guard !title.isEmpty else { return nil }

        let detailRuns = columns.dropFirst().flatMap { ($0.arr("runs") ?? []).compactMap { $0 as? JSONObject } }
        let fixedRuns = (renderer.arr("fixedColumns") ?? []).flatMap {
            (($0 as? JSONObject)?.obj("musicResponsiveListItemFixedColumnRenderer")?.obj("text")?.arr("runs") ?? [])
                .compactMap { $0 as? JSONObject }
        }
        let runs = detailRuns + fixedRuns
        let artist = runs.first { browseId(of: $0)?.hasPrefix("UC") == true }?.str("text")
            ?? runs.compactMap { $0.str("text") }.first(where: isLikelyArtist)
            ?? "Unknown artist"
        let album = runs.first { browseId(of: $0)?.hasPrefix("MPRE") == true }?.str("text")
        let duration = runs.compactMap { $0.str("text") }.compactMap(parseDuration).first

        return Track(videoId: videoId, title: title, artist: artist, album: album,
                     artworkURL: artwork(renderer), durationSeconds: duration)
    }

    private static func parsePanelItem(_ renderer: JSONObject) -> Track? {
        guard let videoId = renderer.str("videoId"), let title = renderer.text("title") else { return nil }
        let byline = (renderer.obj("longBylineText")?.arr("runs") ?? []).compactMap { $0 as? JSONObject }
        let artist = byline.first { browseId(of: $0)?.hasPrefix("UC") == true }?.str("text")
            ?? byline.first?.str("text")
            ?? "Unknown artist"
        let album = byline.first { browseId(of: $0)?.hasPrefix("MPRE") == true }?.str("text")
        let duration = renderer.text("lengthText").flatMap(parseDuration)
        return Track(videoId: videoId, title: title, artist: artist, album: album,
                     artworkURL: artwork(renderer), durationSeconds: duration)
    }

    private static func parseVideoRenderer(_ renderer: JSONObject) -> Track? {
        guard let videoId = renderer.str("videoId"), let title = renderer.text("title") else { return nil }
        let artist = renderer.obj("ownerText").map(runsFirst) ?? renderer.obj("shortBylineText").map(runsFirst) ?? "Unknown artist"
        let duration = renderer.text("lengthText").flatMap(parseDuration)
        return Track(videoId: videoId, title: title, artist: artist, album: nil,
                     artworkURL: artwork(renderer), durationSeconds: duration)
    }

    private static func runsText(_ node: JSONObject) -> String {
        if let simple = node.str("simpleText") { return simple.trimmingCharacters(in: .whitespaces) }
        return (node.arr("runs") ?? []).compactMap { ($0 as? JSONObject)?.str("text") }
            .joined().trimmingCharacters(in: .whitespaces)
    }

    private static func runsFirst(_ node: JSONObject) -> String {
        ((node.arr("runs") ?? []).first as? JSONObject)?.str("text") ?? "Unknown artist"
    }

    private static func browseId(of run: JSONObject) -> String? {
        run.obj("navigationEndpoint")?.obj("browseEndpoint")?.str("browseId")
    }

    private static func isLikelyArtist(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "•" || trimmed == "&" || trimmed == "," { return false }
        if ["song", "video", "episode", "single", "ep", "album"].contains(trimmed.lowercased()) { return false }
        if parseDuration(trimmed) != nil { return false }
        if trimmed.lowercased().contains("views") || trimmed.lowercased().contains("plays") { return false }
        return true
    }

    static func parseDuration(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part), part.count <= 2 || total == 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Largest thumbnail, upgraded to 544px for lh3.googleusercontent artwork.
    private static func artwork(_ renderer: JSONObject) -> URL? {
        let thumbnails = JSONWalk.firstArray(renderer, key: "thumbnails") ?? []
        guard var raw = (thumbnails.last as? JSONObject)?.str("url") else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        if let regex = try? NSRegularExpression(pattern: "=w\\d+-h\\d+") {
            raw = regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "=w544-h544")
        }
        return URL(string: raw)
    }
}
