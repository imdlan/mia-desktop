import Foundation

/// Plain-file secret storage. Deliberately NOT the Apple Keychain: dev builds are
/// ad-hoc signed, so every rebuild changes the binary's identity and the Keychain
/// re-prompts for the login-keychain password — unacceptable UX (releases carry a
/// stable Developer ID now, but the dev loop is where the prompts bit, and this
/// file works for both). Keys are stored unencrypted but
/// user-only readable (0600) at ~/Library/Application Support/Mia/secrets.json —
/// the same trust model as the .env files these keys come from.
enum SecretStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    /// In-memory mirror of the file — reads happen on every UI render (e.g. the
    /// provider switcher filtering by configured keys), so don't hit disk each time.
    /// Only this app writes the file, and all access is main-thread, so this is safe.
    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let cache { return cache }
        let secrets: [String: String]
        if let data = try? Data(contentsOf: fileURL) {
            secrets = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            secrets = [:]
        }
        cache = secrets
        return secrets
    }

    private static func save(_ secrets: [String: String]) {
        cache = secrets
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        // Land 0600 from the first byte. The previous atomic-write-then-chmod
        // left a window — and, on a failed chmod, a permanent state — where the
        // secrets file was group/other readable. A 0600 temp file renamed into
        // place keeps the atomicity of the old write AND the permissions.
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("secrets-\(UUID().uuidString).tmp")
        guard (try? data.write(to: tempURL, options: [.atomic])) != nil,
              (try? FileManager.default.setAttributes(
                  [.posixPermissions: 0o600], ofItemAtPath: tempURL.path
              )) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func get(account: String) -> String? {
        load()[account]
    }

    static func set(_ value: String, account: String) {
        var secrets = load()
        if value.isEmpty {
            secrets.removeValue(forKey: account)
        } else {
            secrets[account] = value
        }
        save(secrets)
    }

    static func delete(account: String) {
        set("", account: account)
    }
}
