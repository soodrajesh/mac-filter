import AppKit

enum PasteDecision {
    case redact
    case allow
    case cancel

    var auditName: String {
        switch self {
        case .redact: return "redacted"
        case .allow: return "allowed"
        case .cancel: return "cancelled"
        }
    }
}

/// The panel shown when a ⌘V has been suppressed.
///
/// Deliberately not an `NSAlert`: `runModal` blocks the main run loop, and the
/// event tap's callback runs on that same run loop — a blocked main thread
/// means macOS decides the tap has timed out and disables it. A non-modal
/// panel with a completion handler keeps the tap alive while the user reads.
final class DecisionPanel: NSObject, NSWindowDelegate {
    private static var active: DecisionPanel?

    private let panel: NSPanel
    private let completion: (PasteDecision) -> Void
    private var finished = false
    private var previewField: NSTextField?
    private var previewToggle: NSButton?

    static func present(text: String,
                        findings: [Finding],
                        destination: Destination,
                        completion: @escaping (PasteDecision) -> Void) {
        // Only ever one panel; a second suppressed paste while this is open
        // would otherwise queue up behind it.
        active?.finish(.cancel)
        let panel = DecisionPanel(text: text, findings: findings, destination: destination, completion: completion)
        active = panel
        panel.show()
    }

    private init(text: String,
                 findings: [Finding],
                 destination: Destination,
                 completion: @escaping (PasteDecision) -> Void) {
        self.completion = completion
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                             styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered,
                             defer: false)
        super.init()

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self

        panel.contentView = buildContent(text: text, findings: findings, destination: destination)
    }

    // MARK: Layout

    private func buildContent(text: String, findings: [Finding], destination: Destination) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let target = destination.detail.map { "\(destination.appName) — \($0)" } ?? destination.appName

        let heading = label("Paste blocked", font: .app(.title))
        let subtitle = label("\(Redactor.summary(of: findings)) found in what you're pasting into \(target).",
                             font: .app(.body),
                             color: .secondaryLabelColor)
        subtitle.preferredMaxLayoutWidth = 396

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(14, after: subtitle)

        for group in Redactor.grouped(findings) {
            stack.addArrangedSubview(findingRow(group))
        }

        // Show what the *pasted result* will actually look like, not just the
        // finding labels — so "Redact & Paste" isn't clicked on faith. Short
        // panels show it open by default; longer ones start collapsed so the
        // panel doesn't dominate the screen, but are always one click away.
        let redactedPreview = Redactor.preview(Redactor.redact(text, findings: findings))
        let showByDefault = text.count <= 300

        let toggle = NSButton(title: showByDefault ? "Hide redacted preview" : "Show redacted preview",
                              target: self, action: #selector(togglePreview))
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.font = .app(.callout, weight: .medium)
        toggle.contentTintColor = .controlAccentColor
        toggle.setAccessibilityIdentifier("preview-toggle")

        let previewField = label(redactedPreview, font: .app(.callout), color: .secondaryLabelColor)
        previewField.isSelectable = true
        previewField.preferredMaxLayoutWidth = 396
        previewField.maximumNumberOfLines = 8
        previewField.isHidden = !showByDefault
        previewField.setAccessibilityIdentifier("redacted-preview")
        self.previewField = previewField
        self.previewToggle = toggle

        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last ?? toggle)
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(previewField)

        let note = label("Nothing has left this Mac. MacFilter makes no network connections.",
                         font: .app(.callout),
                         color: .tertiaryLabelColor)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last ?? note)
        stack.addArrangedSubview(note)

        let allowButton = button("Paste Original", action: #selector(allowTapped), key: "", identifier: "paste-original")
        // The single highest-stakes control in the app should not read as
        // equally safe as "Redact & Paste" when the batch contains a
        // critical finding (a full secret key, a private-key block, …).
        if findings.map(\.severity).max() == .critical {
            allowButton.attributedTitle = NSAttributedString(
                string: "Paste Original",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.app(.body, weight: .semibold)])
        }

        let buttons = NSStackView(views: [
            button("Cancel", action: #selector(cancelTapped), key: "\u{1b}", identifier: "cancel"),
            allowButton,
            button("Redact & Paste", action: #selector(redactTapped), key: "\r", identifier: "redact-and-paste"),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.setCustomSpacing(18, after: note)
        stack.addArrangedSubview(buttons)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -22),
        ])
        return container
    }

    private func findingRow(_ group: (label: String, severity: Severity, count: Int)) -> NSView {
        let dot = label("●", font: .app(.footnote), color: group.severity.color)
        let text = group.count > 1 ? "\(group.label) ×\(group.count)" : group.label
        let name = label(text, font: .app(.body, weight: .medium))
        let severity = label(group.severity.label,
                             font: .app(.callout),
                             color: .tertiaryLabelColor)

        let row = NSStackView(views: [dot, name, severity])
        row.orientation = .horizontal
        row.spacing = 7
        return row
    }

    private func label(_ text: String,
                       font: NSFont,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        return field
    }

    private func button(_ title: String, action: Selector, key: String, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    // MARK: Presentation

    private func show() {
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 440, height: 220))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSSound.beep()
    }

    @objc private func redactTapped() { finish(.redact) }
    @objc private func allowTapped() { finish(.allow) }
    @objc private func cancelTapped() { finish(.cancel) }

    @objc private func togglePreview() {
        guard let previewField, let previewToggle else { return }
        previewField.isHidden.toggle()
        previewToggle.title = previewField.isHidden ? "Show redacted preview" : "Hide redacted preview"
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    /// Closing the window by any route must resolve the pending paste exactly
    /// once, or the interceptor stays stuck with `isPresenting == true` and
    /// silently stops guarding.
    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ decision: PasteDecision) {
        guard !finished else { return }
        finished = true
        panel.delegate = nil
        panel.orderOut(nil)
        if DecisionPanel.active === self { DecisionPanel.active = nil }
        completion(decision)
    }
}
