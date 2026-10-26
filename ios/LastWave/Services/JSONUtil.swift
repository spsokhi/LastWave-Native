import Foundation

/// Small helpers for walking untyped InnerTube JSON, equivalent to the
/// `collectObjects` / `obj` / `array` helpers in InnerTubeMusicApi.kt.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func obj(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func arr(_ key: String) -> [Any]? { self[key] as? [Any] }
    func str(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    /// Joined text of a `{ "runs": [...] }` or `{ "simpleText": ... }` node.
    func text(_ key: String) -> String? {
        guard let node = obj(key) else { return nil }
        if let simple = node.str("simpleText") { return simple }
        let joined = (node.arr("runs") ?? [])
            .compactMap { ($0 as? JSONObject)?.str("text") }
            .joined()
        return joined.isEmpty ? nil : joined
    }
}

enum JSONWalk {
    /// Collects every object stored under `key`, anywhere in the tree, in a
    /// deterministic document-like order (arrays in order, object keys sorted).
    static func collect(_ node: Any, key: String) -> [JSONObject] {
        var out: [JSONObject] = []
        collect(node, key: key, into: &out)
        return out
    }

    private static func collect(_ node: Any, key: String, into out: inout [JSONObject]) {
        if let dict = node as? JSONObject {
            for k in dict.keys.sorted() {
                guard let value = dict[k] else { continue }
                if k == key, let match = value as? JSONObject {
                    out.append(match)
                } else {
                    collect(value, key: key, into: &out)
                }
            }
        } else if let array = node as? [Any] {
            for item in array { collect(item, key: key, into: &out) }
        }
    }

    /// First string value stored under `key`, depth-first.
    static func firstString(_ node: Any, key: String) -> String? {
        if let dict = node as? JSONObject {
            if let s = dict[key] as? String { return s }
            for k in dict.keys.sorted() {
                if let value = dict[k], let found = firstString(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for item in array {
                if let found = firstString(item, key: key) { return found }
            }
        }
        return nil
    }

    /// First array stored under `key`, depth-first.
    static func firstArray(_ node: Any, key: String) -> [Any]? {
        if let dict = node as? JSONObject {
            if let found = dict[key] as? [Any] { return found }
            for k in dict.keys.sorted() {
                if let value = dict[k], let found = firstArray(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for item in array {
                if let found = firstArray(item, key: key) { return found }
            }
        }
        return nil
    }
}
