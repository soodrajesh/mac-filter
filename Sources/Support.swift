import AppKit

// MacGroom-level design system, ported for a pure-AppKit app (MacFilter has
// no SwiftUI views — the decision panel and Settings window are both built
// with NSStackView/NSTextField/NSButton). Same conventions as
// mac-cleanup/Sources/Support.swift, re-expressed with NSFont/NSAppearance
// instead of SwiftUI's Font/.preferredColorScheme:
//   - semantic colors only, never a raw hex
//   - one scale factor (\.textScale's AppKit equivalent) driving every label
//     via `NSFont.app(_:weight:)`, so Settings → Text Size has a real effect
//   - System/Light/Dark stored independently of the OS setting

// MARK: - Appearance

/// System/Light/Dark, independent of the Mac's own appearance setting.
/// Applied via `NSApp.appearance`, which is `nil` for `.system` (defers to
/// macOS) and a concrete `NSAppearance` for the other two — every window,
/// including ones created later (the decision panel, Settings), picks it up
/// automatically since AppKit resolves `effectiveAppearance` from `NSApp`
/// unless a window sets its own.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "appearanceMode"

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppearanceMode {
        get {
            AppearanceMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            apply()
        }
    }

    /// Call once at launch (state may have been set on a previous run) and
    /// again any time `current` changes.
    static func apply() {
        NSApp.appearance = current.nsAppearance
    }
}

// MARK: - Text size

/// Small/Medium/Large/Extra Large. Not SwiftUI's `DynamicTypeSize` — that's
/// an iOS/iPadOS mechanism with no effect on macOS. This is a real scale
/// factor read fresh by `NSFont.app(_:weight:)` at the moment each label is
/// built, so a change in Settings is visible the next time any panel draws
/// (the decision panel and Settings window are both built from scratch each
/// time they're shown, so there's nothing to live-refresh in place).
enum TextSizeSetting: String, CaseIterable {
    case small, medium, large, extraLarge

    static let defaultsKey = "textSize"

    var label: String {
        switch self {
        case .small:      return "Small"
        case .medium:      return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// "Medium" (1.0) is the baseline every point size below was tuned at.
    var scaleFactor: CGFloat {
        switch self {
        case .small:      return 0.9
        case .medium:      return 1.0
        case .large:      return 1.15
        case .extraLarge: return 1.3
        }
    }

    static var current: TextSizeSetting {
        get {
            TextSizeSetting(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// One semantic role → one base point size, matching the sizes the decision
/// panel used as raw `NSFont.systemFont(ofSize:)` calls before this refactor
/// — so this is a drop-in replacement, not a new vocabulary.
enum AppFontStyle {
    case title       // panel heading, e.g. "Paste blocked"
    case body        // subtitle line, finding name
    case callout      // severity label
    case footnote    // privacy note, bullet dot

    var basePointSize: CGFloat {
        switch self {
        case .title:    return 17
        case .body:     return 12
        case .callout:  return 11
        case .footnote: return 10
        }
    }

    var defaultWeight: NSFont.Weight {
        self == .title ? .semibold : .regular
    }
}

extension NSFont {
    /// Replaces `.systemFont(ofSize:weight:)` throughout the app. Reads the
    /// current Text Size setting fresh, so it stays correct even when called
    /// from a window built after Settings last changed.
    static func app(_ style: AppFontStyle, weight: NSFont.Weight? = nil) -> NSFont {
        let scale = TextSizeSetting.current.scaleFactor
        return .systemFont(ofSize: style.basePointSize * scale, weight: weight ?? style.defaultWeight)
    }
}

// MARK: - Status color

extension Severity {
    /// The only place literal colors appear, always paired with meaning:
    /// red = critical/danger, orange = warning, yellow = a step below that —
    /// this app's whole purpose is flagging exactly these three levels, so
    /// every place that shows a `Severity` (the decision panel, the
    /// clipboard-scan alert) should go through this rather than re-deriving
    /// its own mapping. `NSColor.system*` are dynamic system colors, correct
    /// in both light and dark automatically.
    var color: NSColor {
        switch self {
        case .critical: return .systemRed
        case .high:     return .systemOrange
        case .medium:   return .systemYellow
        }
    }
}
