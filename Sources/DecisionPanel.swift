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
        let highestSeverity = findings.map(\.severity).max() ?? .medium

        let headingTile = IconTileView(symbolName: highestSeverity.symbolName, tint: highestSeverity.color, size: 32)
        let heading = label("Paste blocked", font: .app(.title))
        let headingRow = NSStackView(views: [headingTile, heading])
        headingRow.orientation = .horizontal
        headingRow.spacing = 10
        headingRow.alignment = .centerY

        // The count summary ("2 critical, 1 high found") is the single most
        // important line in the panel — it's the answer to "why am I seeing
        // this?" — so it gets its own bold, prominent style. The destination
        // clause is secondary context underneath it, not part of the same
        // sentence weight.
        let summary = label("\(Redactor.summary(of: findings)) found",
                            font: .app(.body, weight: .bold))
        let destinationLine = label("in what you're pasting into \(target).",
                                    font: .app(.callout),
                                    color: .secondaryLabelColor)
        summary.preferredMaxLayoutWidth = 396
        destinationLine.preferredMaxLayoutWidth = 396

        stack.addArrangedSubview(headingRow)
        stack.setCustomSpacing(12, after: headingRow)
        stack.addArrangedSubview(summary)
        stack.setCustomSpacing(2, after: summary)
        stack.addArrangedSubview(destinationLine)
        stack.setCustomSpacing(14, after: destinationLine)

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

        // A calmer, distinct style from the summary above — this is
        // reassurance, not a warning, and green (the app's own accent) is
        // this app's color for "safe/protected".
        let noteTile = IconTileView(symbolName: "lock.shield.fill", tint: .appAccent, size: 20)
        let note = label("Nothing has left this Mac. MacFilter makes no network connections.",
                         font: .app(.footnote),
                         color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = 356
        let noteRow = NSStackView(views: [noteTile, note])
        noteRow.orientation = .horizontal
        noteRow.spacing = 8
        noteRow.alignment = .centerY
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last ?? noteRow)
        stack.addArrangedSubview(noteRow)

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

        let redactButton = button("Redact & Paste", action: #selector(redactTapped), key: "\r", identifier: "redact-and-paste")
        // The success/safe action gets the app's own accent color — green
        // means "protected" throughout MacFilter, and this is the button that
        // puts a protected version of the text on the pasteboard.
        redactButton.bezelColor = .appAccent
        redactButton.contentTintColor = .white
        redactButton.attributedTitle = NSAttributedString(
            string: "Redact & Paste",
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.app(.body, weight: .semibold)])

        let buttons = NSStackView(views: [
            button("Cancel", action: #selector(cancelTapped), key: "\u{1b}", identifier: "cancel"),
            allowButton,
            redactButton,
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.setCustomSpacing(18, after: noteRow)
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

    /// A single finding as a card: a tinted icon tile for its severity, the
    /// label, a severity pill, and a colored left accent bar — the v2 design
    /// system's replacement for a plain text list row.
    private func findingRow(_ group: (label: String, severity: Severity, count: Int)) -> NSView {
        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = group.severity.color.cgColor
        accentBar.layer?.cornerRadius = 1.5
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let tile = IconTileView(symbolName: group.severity.symbolName, tint: group.severity.color, size: 24)

        let text = group.count > 1 ? "\(group.label) ×\(group.count)" : group.label
        let name = label(text, font: .app(.body, weight: .medium))
        let severity = label(group.severity.label,
                             font: .app(.callout, weight: .medium),
                             color: group.severity.color)

        let textStack = NSStackView(views: [name, severity])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let content = NSStackView(views: [accentBar, tile, textStack])
        content.orientation = .horizontal
        content.spacing = 10
        content.alignment = .centerY
        content.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 396).isActive = true
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(name: nil) { appearance in
            appearance.name == .darkAqua || appearance.name == .vibrantDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.035)
        }.cgColor
        card.layer?.cornerRadius = 8
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
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

        // A subtle appear animation — still not a blocking `NSAlert` (see the
        // class doc comment above), just an animated `orderFront`. A gentle
        // scale-and-fade reads as "arriving", not "popping up alarmingly",
        // which matters for a panel whose whole job is to interrupt calmly.
        let finalFrame = panel.frame
        let startFrame = finalFrame.insetBy(dx: finalFrame.width * 0.015, dy: finalFrame.height * 0.015)
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
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
        if DecisionPanel.active === self { DecisionPanel.active = nil }
        // The decision itself must resolve synchronously — the interceptor is
        // waiting on `completion` to release the paste — so only the visual
        // dismissal is animated; `orderOut` follows the fade rather than
        // gating it.
        completion(decision)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }
}
