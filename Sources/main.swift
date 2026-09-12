import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let interceptor = PasteInterceptor()
    private var permissionTimer: Timer?
    private var didWarnOfPermissionLoss = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppearanceMode.apply()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        interceptor.onDecision = { [weak self] in self?.refreshIcon() }

        if !interceptor.arm() {
            requestPermissions()
        }
        refreshIcon()
        startPermissionMonitor()

        // Silent — no alert, no badge if it fails or nothing's newer.
        // `menuNeedsUpdate` picks up the cached result next time the menu
        // opens, and the Settings window's Updates section does the same.
        Task { await UpdateCheckService.checkForUpdate() }
    }

    private func requestPermissions() {
        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
        if !Permissions.hasInputMonitoring { Permissions.requestInputMonitoring() }
    }

    /// Runs for the app's entire lifetime, not just the pre-arm window.
    ///
    /// TCC grants can be revoked at any moment via System Settings — by the
    /// user, or by macOS itself after certain updates — with no notification
    /// to the process. Without this, an app that armed successfully at launch
    /// would never notice a later revocation: `isArmed` would stay `true` and
    /// the menubar would keep showing the solid "guarding" shield while
    /// nothing was actually being scanned. That is the one failure mode this
    /// is not allowed to have, being a security tool.
    private func startPermissionMonitor() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.reconcilePermissions()
        }
    }

    private func reconcilePermissions() {
        let granted = Permissions.allGranted
        if granted, !interceptor.isArmed {
            if interceptor.arm() {
                didWarnOfPermissionLoss = false
                refreshIcon()
            }
        } else if !granted, interceptor.isArmed {
            interceptor.disarm()
            refreshIcon()
            warnOfPermissionLoss()
        }
    }

    /// Shown once per loss, not once ever — if the user regrants and then
    /// loses it again later, they should hear about it again.
    private func warnOfPermissionLoss() {
        guard !didWarnOfPermissionLoss else { return }
        didWarnOfPermissionLoss = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MacFilter stopped guarding"
        alert.informativeText = "Accessibility or Input Monitoring access was turned off in System Settings, "
            + "so MacFilter can no longer check what you paste into AI apps. Grant access again to resume "
            + "protection — until then, pastes go through unchecked."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !Permissions.hasAccessibility {
                Permissions.openAccessibilitySettings()
            } else if !Permissions.hasInputMonitoring {
                Permissions.openInputMonitoringSettings()
            }
        }
    }

    private func refreshIcon() {
        let symbol = interceptor.isArmed ? "shield.lefthalf.filled" : "shield.slash"
        let status = interceptor.isArmed
            ? "MacFilter is watching pastes into AI apps"
            : "MacFilter needs permissions"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        statusItem.button?.toolTip = status
        // The image's accessibilityDescription above covers most VoiceOver
        // cases, but setting it on the button too is what's actually
        // announced when the button itself (not just its image) is the
        // focused accessibility element.
        statusItem.button?.setAccessibilityLabel(status)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(
            title: interceptor.isArmed ? "Guarding pastes into AI apps" : "Inactive — permissions needed",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Always present, even before a single flagged paste — the "Recent"
        // section below only exists once something's been caught, which
        // otherwise leaves a fresh install's menu with nothing to show that
        // the app is actually doing anything. Counts only, never content.
        if interceptor.isArmed {
            let stats = NSMenuItem(
                title: "Session: \(interceptor.pastesChecked) checked · \(interceptor.pastesFlagged) flagged",
                action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
        }

        if !interceptor.isArmed {
            menu.addItem(.separator())
            if !Permissions.hasAccessibility {
                menu.addItem(action("Grant Accessibility…", #selector(openAccessibility)))
            }
            if !Permissions.hasInputMonitoring {
                menu.addItem(action("Grant Input Monitoring…", #selector(openInputMonitoring)))
            }
        }

        if let update = UpdateCheckService.cachedManifest {
            menu.addItem(.separator())
            menu.addItem(action("MacFilter \(update.version) available — Get It", #selector(openUpdateURL)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Scan Clipboard Now", #selector(scanClipboard)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))

        let recent = AuditLog.recentEntries(limit: 5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in recent {
                let kinds = entry.findings.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", ")
                let item = NSMenuItem(title: "  \(entry.decision) → \(entry.destinationApp): \(kinds)",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(action("Reveal Audit Log", #selector(revealLog)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Quit MacFilter", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }

    /// Runs the detectors over whatever is on the clipboard right now and
    /// reports what *would* be caught — the fastest way to sanity-check
    /// detection quality without staging a real paste.
    @objc private func scanClipboard() {
        let alert = NSAlert()
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            alert.messageText = "Clipboard is empty"
            alert.informativeText = "Copy some text first, then scan again."
            alert.runModal()
            return
        }

        let findings = DetectionEngine.standard.scan(text)
        if findings.isEmpty {
            alert.messageText = "Nothing sensitive found"
            alert.informativeText = "Scanned \(text.count) characters. This paste would go through untouched."
        } else {
            alert.messageText = "\(Redactor.summary(of: findings)) found"
            let list = Redactor.grouped(findings)
                .map { "• \($0.label)\($0.count > 1 ? " ×\($0.count)" : "") — \($0.severity.label)" }
                .joined(separator: "\n")
            alert.informativeText = "\(list)\n\nRedacted preview:\n\(Redactor.preview(Redactor.redact(text, findings: findings)))"
        }
        alert.runModal()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openUpdateURL() {
        guard let update = UpdateCheckService.cachedManifest, let url = URL(string: update.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AuditLog.fileURL])
    }

    @objc private func quit() {
        interceptor.disarm()
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
