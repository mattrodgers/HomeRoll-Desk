import Foundation

/// Anmeldeschlüssel je Konto in einer Datei, die nur der eigene Mac-Benutzer lesen darf
/// (~/Library/Application Support/HomeRoll Desktop/accounts.json, Ordner 700, Datei 600).
/// Grund: Die App ist ad hoc signiert – mit dem Schlüsselbund fragte der Mac nach jedem Update nach dem
/// Schlüsselbund-Passwort. Der Inhalt ist ein Sitzungs-Token für den eigenen Immich-Server (kein Passwort), abmelden löscht ihn.
enum TokenStore {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "HomeRoll Desktop Test" : "HomeRoll Desktop")
    }
    private static var file: URL { dir.appendingPathComponent("accounts.json") }
    private static let lock = NSLock()

    private static func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }

    static func get(_ id: String) -> String? { lock.withLock { load()[id] } }

    static func set(_ token: String?, for id: String) {
        lock.withLock {
            var all = load()
            all[id] = token
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            guard let d = try? JSONEncoder().encode(all) else { return }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try? d.write(to: file, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func token(for id: String) -> String? { get(id) }
}
