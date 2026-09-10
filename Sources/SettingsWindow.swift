import AppKit

/// PasteGuard's one Settings window (⌘,), opened from the menubar menu.
///
/// Two sections, in the same order as mac-cleanup's `SettingsView`:
/// Appearance (System/Light/Dark) then Text Size (Small/Medium/Large/Extra
/// Large). No License section — PasteGuard stays fully free while its core
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

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "PasteGuard Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
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
