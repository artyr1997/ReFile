import Foundation
import SQLite3

// What ReFile keeps between launches: the mode, PLAY's tab, the order, FULL for videos, where each book was left. Each a JSON text in a file of its own, as the app kept them before in its
// web view's storage; those are brought over once, the first time.

enum Saved {
    /// the app's own folder (TDLib's database and CHAT's folder are in it too)
    /// another folder in its place (--render draws its pages from what it makes up there)
    static var root: URL?

    static let dir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root ?? support.appendingPathComponent("com.artursavytskyi.refile")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let state: URL = {
        let state = dir.appendingPathComponent("state")
        if !FileManager.default.fileExists(atPath: state.path) && root == nil {
            try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            bringOver(into: state)
        }
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        return state
    }()

    static func get(_ key: String) -> String? {
        try? String(contentsOf: state.appendingPathComponent(key + ".json"), encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        try? value.write(to: state.appendingPathComponent(key + ".json"), atomically: true, encoding: .utf8)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: state.appendingPathComponent(key + ".json"))
    }

    static func json(_ key: String) -> Any? {
        guard let text = get(key) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// a word kept on its own (a mode, a tab)
    static func word(_ key: String) -> String? {
        guard let text = get(key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? String
    }

    static func setWord(_ key: String, _ value: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return }
        set(key, String(decoding: data, as: UTF8.self))
    }

    static func setJSON(_ key: String, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        set(key, text)
    }

    /// what the app kept in its web view (WebKit's local storage): each key's text, as it was
    private static func bringOver(into state: URL) {
        let web = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/com.artursavytskyi.refile")
        guard let found = FileManager.default.enumerator(at: web, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "localstorage.sqlite3" }) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(found.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        // where each book was left: one file for them all
        var books: [String: Any] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let key = String(cString: k)
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
            // WebKit keeps the values in UTF-16
            guard let value = String(data: data, encoding: .utf16LittleEndian) else { continue }
            if key.hasPrefix("book:") {
                books[String(key.dropFirst(5))] = try? JSONSerialization.jsonObject(with: Data(value.utf8))
                continue
            }
            // what was kept as a bare word (a mode, a tab) kept as JSON text
            let json = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) != nil ? value : "\"\(value)\""
            try? json.write(to: state.appendingPathComponent(key + ".json"), atomically: true, encoding: .utf8)
        }
        if !books.isEmpty, let data = try? JSONSerialization.data(withJSONObject: books) {
            try? data.write(to: state.appendingPathComponent("books.json"))
        }
    }
}
