import CryptoKit
import Foundation
import Security

enum LastFmError: LocalizedError {
    case missingCredentials
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Enter your Last.fm API key and shared secret first"
        case .api(let message): return message
        }
    }
}

/// Last.fm scrobbler (https://www.last.fm/api/scrobbling). Uses the user's own
/// API account, entered in Settings, plus a mobile session from their login.
@MainActor
final class LastFm: ObservableObject {
    static let shared = LastFm()

    @Published var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: "lastfm.apiKey") } }
    @Published var apiSecret: String { didSet { Keychain.set(apiSecret, for: "lastfm.apiSecret") } }
    @Published private(set) var username: String?
    @Published var scrobblingEnabled: Bool { didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: "lastfm.enabled") } }

    private var sessionKey: String?

    var isConnected: Bool { sessionKey != nil && username != nil }

    private init() {
        apiKey = UserDefaults.standard.string(forKey: "lastfm.apiKey") ?? ""
        apiSecret = Keychain.get("lastfm.apiSecret") ?? ""
        username = UserDefaults.standard.string(forKey: "lastfm.username")
        scrobblingEnabled = UserDefaults.standard.object(forKey: "lastfm.enabled") as? Bool ?? true
        sessionKey = Keychain.get("lastfm.sessionKey")
    }

    func login(username: String, password: String) async throws {
        guard !apiKey.isEmpty, !apiSecret.isEmpty else { throw LastFmError.missingCredentials }
        let response = try await call([
            "method": "auth.getMobileSession",
            "username": username,
            "password": password,
        ])
        guard let session = response.obj("session"), let key = session.str("key") else {
            throw LastFmError.api("Last.fm did not return a session")
        }
        sessionKey = key
        self.username = session.str("name") ?? username
        Keychain.set(key, for: "lastfm.sessionKey")
        UserDefaults.standard.set(self.username, forKey: "lastfm.username")
    }

    func logout() {
        sessionKey = nil
        username = nil
        Keychain.set(nil, for: "lastfm.sessionKey")
        UserDefaults.standard.removeObject(forKey: "lastfm.username")
    }

    func updateNowPlaying(_ track: Track) {
        guard scrobblingEnabled, let sessionKey else { return }
        var params = trackParams(track)
        params["method"] = "track.updateNowPlaying"
        params["sk"] = sessionKey
        Task { _ = try? await call(params) }
    }

    func scrobble(_ track: Track, startedAt: Date) {
        guard scrobblingEnabled, let sessionKey else { return }
        var params = trackParams(track)
        params["method"] = "track.scrobble"
        params["timestamp"] = String(Int(startedAt.timeIntervalSince1970))
        params["sk"] = sessionKey
        Task { _ = try? await call(params) }
    }

    private func trackParams(_ track: Track) -> [String: String] {
        var params = [
            "artist": LyricsService.cleanArtist(track.artist),
            "track": LyricsService.cleanTitle(track.title),
        ]
        if let album = track.album { params["album"] = album }
        if let duration = track.durationSeconds { params["duration"] = String(duration) }
        return params
    }

    private func call(_ parameters: [String: String]) async throws -> JSONObject {
        guard !apiKey.isEmpty, !apiSecret.isEmpty else { throw LastFmError.missingCredentials }
        var params = parameters
        params["api_key"] = apiKey
        let signatureBase = params.keys.sorted().map { $0 + params[$0]! }.joined() + apiSecret
        params["api_sig"] = Insecure.MD5.hash(data: Data(signatureBase.utf8))
            .map { String(format: "%02x", $0) }.joined()
        params["format"] = "json"

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw LastFmError.api("Unexpected response from Last.fm")
        }
        if let message = json.str("message"), json["error"] != nil {
            throw LastFmError.api(message)
        }
        return json
    }
}

/// Minimal generic-password Keychain wrapper for secrets.
enum Keychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
