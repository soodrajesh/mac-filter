import Foundation

/// Per-(finding kind × destination app) "don't ask again" memory.
///
/// This is the audit's "POC-appropriate, not the full policy-layer version"
/// fix (see `UX-AUDIT.md` §1.2): a lightweight toggle, not the persisted
/// allowlist + management UI + audit-log interaction a real policy layer
/// would need. Deliberately scoped to (kind × destination) rather than a
/// global mute, so dismissing a false-positive card number in one app can't
/// silently suppress a real card number pasted somewhere else.
///
/// Stored in `UserDefaults`, not Keychain — this is a UX preference (what to
/// stop asking about), not a secret, and matches the app's existing
/// `UserDefaults`-based preference storage (text size, appearance).
enum SuppressionStore {
    private static let defaultsKey = "com.rajeshsood.macfilter.suppressedFindings"

    /// "kind|appName" — appName rather than bundleID because that's what the
    /// panel and audit log already key on (`Destination.appName`), and it's
    /// what a user would recognize if a future Settings pane ever lists
    /// these back to them.
    private static func key(kind: String, appName: String) -> String {
        "\(kind)|\(appName)"
    }

    static func isSuppressed(kind: String, appName: String) -> Bool {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return stored.contains(key(kind: kind, appName: appName))
    }

    static func suppress(kind: String, appName: String) {
        var stored = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        stored.insert(key(kind: kind, appName: appName))
        UserDefaults.standard.set(Array(stored), forKey: defaultsKey)
    }

    /// Not wired into any UI yet (no Settings pane lists/clears individual
    /// entries) — provided so a future "Reset all suppressed findings"
    /// Settings button, or a test, doesn't need to know the storage key.
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// For a future Settings list — human-readable "kind → app" pairs.
    static var allSuppressed: [(kind: String, appName: String)] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return stored.compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (kind: String(parts[0]), appName: String(parts[1]))
        }
    }
}
