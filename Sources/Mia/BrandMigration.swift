import Foundation

/// One-time migration from the PopChat era. The rename changed three things at
/// once — the bundle ID (com.chenle.PopChat → app.tapfun.mia), the Application
/// Support directory (PopChat → Mia) and the KeyboardShortcuts name
/// (togglePopChat → toggleMia) — and each change silently orphans data the new
/// app still needs: settings (UserDefaults.standard is keyed by bundle ID, so
/// every pre-rename preference vanished), conversations and secrets.json (both
/// live under the data directory), and the global hotkey (KeyboardShortcuts
/// persists under "KeyboardShortcuts_<name>"). This runs once at launch and
/// stitches the old state onto the new identity. It never deletes: the worst
/// outcome of any step is a copied key or a renamed directory, both of which
/// are recoverable.
enum BrandMigration {
    static let legacyAppID = "com.chenle.PopChat"
    static let migratedFlagKey = "brandMigratedFromPopChat"

    // KeyboardShortcuts persists under its userDefaultsPrefix ("KeyboardShortcuts_")
    // + the shortcut name, and the name changed with the app — so the stored key
    // has to be renamed too, or the user's chosen hotkey resets to the default.
    private static let legacyHotkeyKey = "KeyboardShortcuts_togglePopChat"
    private static let hotkeyKey = "KeyboardShortcuts_toggleMia"

    /// The production entry point: real domain, real directories, once.
    static func migrate() {
        _ = migrate(appSupportRoot: nil, legacyAppID: legacyAppID, defaults: .standard, force: false)
    }

    /// Copies the pre-rename state onto the new identity. Every parameter is
    /// injectable so the smoke harness can drive the whole flow against a
    /// throwaway domain and temp directory — the real ones must never be
    /// touched by a test. Returns the actions taken, for the harness to assert
    /// on and for a debug launch to read.
    @discardableResult
    static func migrate(
        appSupportRoot: URL? = nil,
        legacyAppID: String = BrandMigration.legacyAppID,
        defaults: UserDefaults = .standard,
        force: Bool = false
    ) -> [String] {
        // Idempotence gate: once the flag is set there is nothing left to do,
        // and re-running would race whatever the user has changed since.
        if defaults.bool(forKey: migratedFlagKey), !force { return [] }
        var actions: [String] = []

        // 1. Old defaults domain. The bundle-ID change means UserDefaults
        // .standard now reads a different plist file; CFPreferences can still
        // address the old domain explicitly. Copy key by key and never
        // overwrite — anything the new app has already written wins.
        if let keys = CFPreferencesCopyKeyList(
            legacyAppID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? [String] {
            var copied = 0
            for key in keys {
                guard let value = plistValue(for: key, appID: legacyAppID),
                      defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                copied += 1
            }
            if copied > 0 {
                actions.append("copied \(copied) default\(copied == 1 ? "" : "s") from \(legacyAppID)")
            }
        }

        // 2. Hotkey rename. The copy above brought the shortcut over under its
        // OLD key; move it to the new one (only when the new one is unset, so a
        // shortcut recorded after the rename is never clobbered).
        if defaults.object(forKey: hotkeyKey) == nil,
           let shortcut = defaults.object(forKey: legacyHotkeyKey) {
            defaults.set(shortcut, forKey: hotkeyKey)
            defaults.removeObject(forKey: legacyHotkeyKey)
            actions.append("renamed \(legacyHotkeyKey) → \(hotkeyKey)")
        }

        // 3. Data directory. conversations/ and secrets.json moved with the
        // name, so a post-rename install looks like a fresh one. moveItem is an
        // atomic same-volume rename; when BOTH directories exist (the user ran
        // both builds) neither is touched — merging or deleting either side
        // would destroy data the user can still see.
        let root = appSupportRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = root.appendingPathComponent("PopChat", isDirectory: true)
        let newDir = root.appendingPathComponent("Mia", isDirectory: true)
        let files = FileManager.default
        let oldExists = files.fileExists(atPath: oldDir.path)
        let newExists = files.fileExists(atPath: newDir.path)
        if oldExists, !newExists {
            do {
                try files.moveItem(at: oldDir, to: newDir)
                actions.append("moved \(oldDir.path) → \(newDir.path)")
            } catch {
                actions.append("could not move \(oldDir.path): \(error.localizedDescription)")
            }
        } else if oldExists, newExists {
            actions.append("kept both \(oldDir.lastPathComponent)/ and \(newDir.lastPathComponent)/ — nothing moved")
        }
        // Old directory absent: fresh install or already moved — nothing to do.

        defaults.set(true, forKey: migratedFlagKey)
        return actions
    }

    /// CFPreferencesCopyValue is declared to return a CFPropertyList, but
    /// UserDefaults traps at runtime on anything outside the plist value types,
    /// so bridge through the concrete class before handing the value over.
    private static func plistValue(for key: String, appID: String) -> Any? {
        guard let raw = CFPreferencesCopyValue(
            key as CFString, appID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) else { return nil }
        switch raw {
        case let number as NSNumber: return number
        case let string as NSString: return string
        case let data as NSData: return data
        case let array as NSArray: return array
        case let dictionary as NSDictionary: return dictionary
        default: return nil
        }
    }
}
