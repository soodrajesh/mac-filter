import AppKit

/// MacFilter's one Settings window (⌘,), opened from the menubar menu.
///
/// Two sections, in the same order as mac-cleanup's `SettingsView`:
/// Appearance (System/Light/Dark) then Text Size (Small/Medium/Large/Extra
/// Large). No License section — MacFilter stays fully free while its core
/// feature (proven end-to-end interception) is still unproven; monetization
/// is deliberately deferred, not merely unbuilt yet. No app-specific
/// preferences yet either — nothing here needs one.
///
/// Plain AppKit, matching the rest of the app: there's no SwiftUI
/// `WindowGroup`/`Settings` scene to hang a "Settings not inheriting the
/// main window's environment" concern on (the mac-cleanup doc's caveat about
/// that is a SwiftUI-Settings-scene-specific issue), but the same principle
/// holds regardless — every control here reads and writes `UserDefaults`
/// directly rather than assuming state handed down from elsewhere.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var appearanceButtons: [AppearanceMode: NSButton] = [:]
    private var textSizeButtons: [TextSizeSetting: NSButton] = [:]
    private var verificationCommands = ""

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "MacFilter Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = buildContent()
        window.contentView = content
        // Fixed contentRect above is just a starting point; the About section's
        // wrapped body text makes the real height content-dependent.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // First, not last: a skeptical user evaluates a trust claim like this
        // one at install time, not only after they happen to trigger a block.
        stack.addArrangedSubview(section(title: "About", body: aboutSection()))
        stack.addArrangedSubview(section(title: "Appearance", body: appearancePicker()))
        stack.addArrangedSubview(section(title: "Text Size", body: textSizePicker()))

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func section(title: String, body: NSView) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .app(.body, weight: .semibold)

        let stack = NSStackView(views: [heading, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func aboutSection() -> NSView {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let versionLabel = NSTextField(labelWithString: "MacFilter \(version) (\(build))")
        versionLabel.font = .app(.body, weight: .medium)

        let claim = NSTextField(wrappingLabelWithString:
            "Nothing pasted through MacFilter ever leaves this Mac. The app makes no network "
            + "connections — verify it yourself with the commands below.")
        claim.font = .app(.callout)
        claim.textColor = .secondaryLabelColor
        claim.preferredMaxLayoutWidth = 336

        verificationCommands = "otool -L /Applications/MacFilter.app/Contents/MacOS/MacFilter\n"
            + "nm -u /Applications/MacFilter.app/Contents/MacOS/MacFilter"
        let commandsField = NSTextField(labelWithString: verificationCommands)
        commandsField.font = .monospacedSystemFont(ofSize: AppFontStyle.callout.basePointSize
                                                     * TextSizeSetting.current.scaleFactor,
                                                     weight: .regular)
        commandsField.textColor = .labelColor
        commandsField.isSelectable = true
        commandsField.maximumNumberOfLines = 2
        commandsField.lineBreakMode = .byTruncatingTail
        commandsField.preferredMaxLayoutWidth = 336

        let copyButton = NSButton(title: "Copy Verification Commands",
                                  target: self, action: #selector(copyVerificationCommands))
        copyButton.bezelStyle = .rounded
        copyButton.font = .app(.callout)

        let stack = NSStackView(views: [versionLabel, claim, commandsField, copyButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: claim)
        stack.setCustomSpacing(10, after: commandsField)
        return stack
    }

    @objc private func copyVerificationCommands() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(verificationCommands, forType: .string)
    }

    private func appearancePicker() -> NSView {
        let buttons = AppearanceMode.allCases.map { mode -> NSButton in
            let button = radioButton(title: mode.label, symbol: mode.symbol,
                                     isOn: mode == AppearanceMode.current,
                                     action: #selector(appearanceChanged(_:)))
            appearanceButtons[mode] = button
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func textSizePicker() -> NSView {
        let buttons = TextSizeSetting.allCases.map { size -> NSButton in
            let button = radioButton(title: size.label, symbol: nil,
                                     isOn: size == TextSizeSetting.current,
                                     action: #selector(textSizeChanged(_:)))
            textSizeButtons[size] = button
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func radioButton(title: String, symbol: String?, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: action)
        button.font = .app(.body)
        button.state = isOn ? .on : .off
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    // MARK: Actions

    @objc private func appearanceChanged(_ sender: NSButton) {
        guard let (mode, _) = appearanceButtons.first(where: { $0.value === sender }) else { return }
        AppearanceMode.current = mode
        for (candidate, button) in appearanceButtons { button.state = candidate == mode ? .on : .off }
    }

    @objc private func textSizeChanged(_ sender: NSButton) {
        guard let (size, _) = textSizeButtons.first(where: { $0.value === sender }) else { return }
        TextSizeSetting.current = size
        for (candidate, button) in textSizeButtons { button.state = candidate == size ? .on : .off }
    }
}
