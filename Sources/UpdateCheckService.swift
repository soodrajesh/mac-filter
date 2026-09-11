import Foundation

/// The manifest MacFilter polls to learn a newer version exists — same
/// shape and endpoint as MacGroom's `UpdateCheckService` (see mac-groom's
/// Sources/Services/UpdateCheckService.swift), parameterized with
/// `app=macfilter` so gogenops.com/api/update-check serves MacFilter's own
/// manifest (gogenops.com/mac-apps/macfilter/updates.json) instead of
/// defaulting to MacGroom's.
struct UpdateManifest: Codable, Equatable {
    let version: String
    let notes: String?
    let url: String
}

/// Lightweight, safe update *checking* — not silent auto-update. Compares
/// the hosted manifest's version against this build's own
/// `CFBundleShortVersionString` and, if newer, hands back the manifest so
/// the menu and Settings window can point the user at it. Never downloads
/// or replaces the running app bundle.
enum UpdateCheckService {
    /// Set once at launch (and again on demand from Settings' "Check for
    /// Updates" button) and read by both `menuNeedsUpdate` and the Settings
    /// window — MacFilter has no persistent ObservableObject the way
    /// mac-groom's SweepModel is, so this cache is the one place both UI
    /// surfaces agree on what was last found.
    static private(set) var cachedManifest: UpdateManifest?

    @discardableResult
    static func checkForUpdate() async -> UpdateManifest? {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        var components = URLComponents(string: "https://gogenops.com/api/update-check")!
        components.queryItems = [
            URLQueryItem(name: "app", value: "macfilter"),
            URLQueryItem(name: "v", value: currentVersion),
            URLQueryItem(name: "os", value: macOSVersionString()),
        ]

        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            cachedManifest = nil
            return nil
        }

        let result = isNewer(manifest.version, than: currentVersion) ? manifest : nil
        cachedManifest = result
        return result
    }

    private static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Component-wise numeric comparison ("1.10" > "1.9"), not a string
    /// compare (which would get that backwards) — pads the shorter side
    /// with zeros so "1.2" vs "1.2.1" compares correctly too.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
