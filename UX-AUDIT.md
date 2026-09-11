# PasteGuard — UI/UX & Functional Audit

**Scope:** static/code-driven audit of the v0.1 POC. No live GUI automation was performed (per
instruction); every claim below is traced directly to source (file:line references throughout).
Evaluated against Apple's Human Interface Guidelines and Nielsen's 10 usability heuristics, weighted
toward the app's core promise — *protect sensitive data without being annoying* — and its own stated
trust claim of zero network calls.

**Files read in full:** `Sources/main.swift`, `Sources/DecisionPanel.swift`,
`Sources/SettingsWindow.swift`, `Sources/Support.swift`, `Sources/Detectors.swift`,
`Sources/Redactor.swift`, `Sources/PasteInterceptor.swift`, `Sources/AISurfaces.swift`,
`Sources/Permissions.swift`, `Sources/AuditLog.swift`, `README.md`.

**Overall polish: 7/10 — relative to POC stage.** This is not a polish score against a shipped
paid utility (it would score much lower there — no About panel, no onboarding, no visible version,
one hand-rolled AppKit window). Relative to "week-one proof of concept," the engineering discipline
is well above average: a real semantic design system (`NSFont.app`, `AppearanceMode`,
`TextSizeSetting`) already threaded through every view, a genuinely defensive event-tap lifecycle
(re-arming on timeout, single-resolution guarantee on the decision panel, bypass-marker + fallback
window for the synthetic paste), and an audit log that structurally cannot leak the thing it's
supposed to protect. The gaps that exist are concentrated exactly where the README itself says they
are: fail-safe behavior after the initial permission grant, and the unverified live-interception
path. Those are the two areas this audit weights most heavily.

**Fix pass (2026-09-10):** all Critical/High findings addressed except 1.2 (false-positive
suppression, correctly deferred per the audit's own effort categorization — it's a policy-layer
feature, not a cheap fix) and 6.2 (browser title/timing fragility, which needs live verification
before a code fix can be made correctly, per the audit's own §6.5). All Medium findings marked
Fixed above were addressed; Low findings were left alone except 4.4, which was essentially free
alongside other `DecisionPanel` changes. See each finding's own section below for what changed and
why anything was skipped.

---

## Top issues, ranked by severity/impact

| # | Finding | Category | Severity | Status |
|---|---|---|---|---|
| 1 | Permission revocation after launch is never re-checked — protection can silently stop working while the icon still shows "guarding" | Fail-Safe Behavior | **Critical** | **Fixed** |
| 2 | The real decision panel (used for actual live pastes) never shows a redacted preview before the user commits to "Redact & Paste" — only the separate manual "Scan Clipboard" debug path does | Detection & Decision UX | High | **Fixed** |
| 3 | The zero-network trust claim is not surfaced anywhere reachable on demand — no About panel, no Settings mention, no version number; it only appears inside a block panel a user may never trigger | Trust & Transparency | High | **Fixed** |
| 4 | No mechanism to learn from or suppress a recurring false positive — every session re-triggers on the same harmless pattern, which is the exact failure mode the README warns kills tools in this category | Detection & Decision UX | High | Skipped — see note below |
| 5 | AI-surface detection is fragile in ways that plausibly explain the README's "not yet exercised end to end": a todesktop-generated bundle ID for Cursor, title-substring matching for browsers, and terminal AI agents (Claude Code, Aider) not recognized as a surface at all — already confirmed failing live per the README | Readiness Gap | High | **Partially fixed** — see 6.1–6.3 below |
| 6 | "Paste Original" and "Redact & Paste" are visually identical-weight buttons with no risk-based distinction, on the single highest-stakes decision point in the app | Detection & Decision UX | Medium | **Fixed** |
| 7 | Browser AI-surface detection silently disables (passes every paste through unchecked) if Accessibility trust is lost mid-session, with no distinct signal from "native-app paste correctly ignored" | Fail-Safe Behavior | Medium | **Fixed** (via 3.1's fix, as the audit predicted) |

---

## 1. Detection & Decision UX

### 1.1 No redacted preview before commit in the real flow (High) — **Fixed**
`DecisionPanel` now redacts the pasted text and shows the result inline (`Sources/DecisionPanel.swift`,
the "Show/Hide redacted preview" disclosure), reusing `Redactor.redact` and a new shared
`Redactor.preview` truncation helper so the preview itself stays capped. Panels for pastes ≤300
characters show it open by default; longer ones start collapsed, one click away, per the audit's own
suggested threshold.
`Sources/DecisionPanel.swift:63-113` builds the panel shown on an actual intercepted ⌘V. It shows
finding labels, severities and counts (via `Redactor.grouped`), but never calls
`Redactor.redact(text, findings:)` to show what the *pasted result* will actually look like. The
user clicks "Redact & Paste" (the default, bound to Return — `DecisionPanel.swift:96`) on faith.

Contrast with `Sources/main.swift:117-127` (`scanClipboard`, the manual debug tool), which *does*
build and display `preview(Redactor.redact(text, findings: findings))` in the alert. The feature the
audit brief specifically asks about — "does the user see a preview of the redacted version before
committing to paste it?" — exists, but only in the tool nobody uses during a real paste.

**Why it matters:** redaction replacement strings are not always obviously correct at a glance
(`[AWS SECRET REDACTED]` vs. a card number's `**** **** **** 1111` vs. an email's partial mask) —
a user pressing Return by habit has no way to catch a redaction that garbled surrounding text
(e.g. two overlapping matches, or a private-key block redaction leaving a dangling PEM footer) before
it lands in the AI tool.

**Fix:** add a collapsed "Preview redacted text" disclosure (or auto-show for panels under ~300
characters) inside `buildContent`, reusing the same `Redactor.redact` call `scanClipboard` already
makes. Keep it capped/truncated exactly as `main.swift:131-133` already does, so the preview itself
never becomes a way to leak the sensitive spans onto screen unbounded.

### 1.2 No false-positive learning or suppression (High) — **Fixed (2026-09-11, POC-scoped)**
Implemented exactly the "POC-appropriate, not the full policy-layer version" fix this finding's
own writeup below already specified: a "Don't ask again for this, here" checkbox on each finding
row in `DecisionPanel`, scoped to (finding kind × destination app), persisted in `UserDefaults` via
the new `SuppressionStore.swift`. `PasteInterceptor.handle` now filters findings through
`SuppressionStore.isSuppressed` before deciding whether to present the panel at all — if every
finding present was previously suppressed for this app, the real ⌘V passes through untouched
(not even swallowed) and the event is still written to the audit log as `"allowed (suppressed)"`,
so silent-but-invisible was avoided. If only some findings are suppressed, the panel still appears
for the rest — a previously-dismissed IBAN false positive doesn't hide a newly-appearing AWS key
in the same paste.

Deliberately still not built: an admin-managed allowlist, custom detector patterns, or a "never
allow critical" enforcement mode — those remain the real policy-layer scope, now more precisely
described in the README's Known Gaps rather than conflated with this simpler per-user toggle.
No UI yet lists or clears individual suppressed entries (`SuppressionStore.allSuppressed`/
`.clearAll()` exist for a future Settings pane to use). 50/50 tests still pass; build clean.


`Detectors.swift` has real false-positive defense at the *pattern* level — Luhn/mod-97/PPSN
checksums, Shannon-entropy gating, the `Placeholder` word/shape rejection list (`Detectors.swift:219-239`).
That is genuinely good engineering. But there is no mechanism anywhere in `DecisionPanel`,
`AuditLog`, or `PasteInterceptor` for a *specific* recurring value or pattern the user has already
dismissed once to be trusted going forward — every session re-flags the exact same harmless string.

Grep confirms nothing like an allowlist exists:

```
$ grep -rn "allowlist\|whitelist\|trusted\|suppress\|mute\|ignore" Sources/
(no matches for a user-facing suppression mechanism)
```

This is called out honestly in the README's "Known gaps" ("No policy layer... per-org allowlists...
are what a paid tier would be built from"), so it's a known, not hidden, gap — but it is worth
elevating here because it is the single biggest determinant of whether "Paste Original" becomes a
reflex. A user who hits the same false positive three times in a week will start pressing the
unguarded button without reading the panel at all, at which point a genuine critical finding gets
the same one-click dismissal.

**Fix (POC-appropriate, not the full policy-layer version):** a lightweight "Don't ask again for
this" per-finding-kind-plus-destination-app toggle, persisted in `UserDefaults`, checked before
`isPresenting` is set in `PasteInterceptor.handle` (`PasteInterceptor.swift:130-139`). Scoping it to
(finding kind × destination) rather than a global mute keeps a card-number false positive in one
context from silencing a real card number pasted somewhere else.

### 1.3 No visual risk distinction between the three buttons (Medium) — **Fixed**
"Paste Original" is now rendered in `.systemRed` with a heavier weight whenever the batch's highest
severity is `.critical` (`findings.map(\.severity).max()`, already available as suggested).
Kept to the "at minimum" fix from the audit rather than adding a second confirmation step, to avoid
adding friction to the common case where nothing critical is present.


`DecisionPanel.swift:93-101`:
```swift
let buttons = NSStackView(views: [
    button("Cancel", action: #selector(cancelTapped), key: "\u{1b}"),
    button("Paste Original", action: #selector(allowTapped), key: ""),
    button("Redact & Paste", action: #selector(redactTapped), key: "\r"),
])
```
All three use the same `button(_:action:key:)` helper (`DecisionPanel.swift:140-145`) — same
`.rounded` bezel, no color, no `.destructive`-style treatment, no secondary confirmation for
"Paste Original" when the highest severity present is `.critical`. The only friction difference is
that "Paste Original" has no key equivalent, which is a real (if subtle) piece of good design — it
can't be triggered by muscle-memory Return — but visually the three buttons read as equally safe
choices. HIG's guidance on destructive actions (visual weight/color should track consequence, not
just default-vs-not) is not applied here.

**Fix:** at minimum, tint "Paste Original" with `.systemOrange`/`.systemRed`-adjacent styling when
the batch contains a `.critical` finding (the data needed — `findings.map(\.severity).max()` — is
already computed for `AuditLog` at `AuditLog.swift:47` and trivially available here too). Consider
requiring a second click ("Paste Original" → confirms to "Paste Anyway?") only when a critical
finding is present, so genuinely risky over-rides carry more friction than a medium-severity email
address.

### 1.4 Panel content strikes the right balance on not leaking data (positive finding)
Worth stating explicitly since the brief asks: the panel shows category + severity + count
(`Redactor.grouped`, `Redactor.swift:30-42`) and never the matched string itself. This is the
correct trade-off for a security tool — informative enough to make the redact/allow/cancel decision,
without turning the decision panel itself into a second place the sensitive value is displayed in
plaintext on screen (which `scanClipboard`'s alert, by contrast, does risk via its preview — see 3.3
below). No fix needed here; flagged as confirmation the core panel got this right.

---

## 2. Trust & Transparency

### 2.1 Zero-network claim is not reachable on demand (High) — **Fixed**
Added an "About" section to `SettingsWindow` — shown first, before Appearance/Text Size — with the
app name/version, the restated trust claim, and both `otool -L`/`nm -u` verification commands
(monospaced, selectable, plus a "Copy Verification Commands" button). Also added an
"About PasteGuard…" item to the menubar menu, so the trust claim is reachable at install time, not
only inside a block panel.


The README leads with this as the core trust claim, with verification commands (`otool -L`,
`nm -u`). Inside the app, the claim appears in exactly one place: the decision panel's footer note
—

```swift
let note = label("Nothing has left this Mac. PasteGuard makes no network connections.", ...)
```
(`DecisionPanel.swift:87-89`)

That only renders when a paste has already been *blocked*. A user who installs PasteGuard, sees the
solid-shield icon, and never happens to trigger a flagged paste in their first days of use has no
in-app way to see this claim at all — they'd have to go back to GitHub. `SettingsWindowController`
(`SettingsWindow.swift`) has exactly two sections, Appearance and Text Size — no About, no version,
no restated trust claim, no link to the verification commands. There is also no "About PasteGuard"
item in the menubar menu (`main.swift:51-92` enumerates every item; there isn't one).

**Why it matters:** for a tool whose entire pitch is "trust us because you can verify it, not
because we say so," burying the one reinforcing UI moment behind a conditional event undercuts the
pitch. A skeptical user — exactly the persona this app is built for — evaluates trust claims at
install time, not at first-block time.

**Fix:** add a minimal About section to Settings (or a separate "About PasteGuard…" menu item):
app name/version, the same one-line claim, and ideally the two verification commands as
copy-to-clipboard text so a technical buyer can paste them straight into Terminal without retyping.

### 2.2 No version number surfaced anywhere (Medium) — **Fixed**
Folded into the 2.1 fix: the About section reads `CFBundleShortVersionString`/`CFBundleVersion` from
`Bundle.main.infoDictionary` directly, so it always reflects the running build.


Neither the menu (`main.swift`) nor Settings (`SettingsWindow.swift`) displays a build/version
string. For a self-distributed POC being iterated on (already several README/behavior revisions per
`git log`), a user reporting a bug or a reviewer coming back to re-test has no way to confirm which
build they're running without checking `Info.plist` manually. Trivial fix, worth doing alongside 2.1.

---

## 3. Fail-Safe Behavior (weighted heavily — this is a security tool)

### 3.1 Permission revocation after arming is never re-checked (Critical) — **Fixed**
`AppDelegate` now runs a 10-second `startPermissionMonitor()` timer for the app's entire lifetime
(`Sources/main.swift`), not just the pre-arm window. On a granted → revoked transition it calls
`interceptor.disarm()`, refreshes the menubar icon to the slashed-shield state immediately, and shows
a one-time (per loss) `NSAlert` explaining protection has stopped and offering to open the relevant
System Settings pane. On a revoked → granted transition it re-arms and clears the alert flag so a
second future loss is announced again too. This also directly fixes 3.2 and issue 7 in the summary
table, exactly as the audit predicted it would.


Trace through `main.swift:8-34`:

```swift
if !interceptor.arm() {
    requestPermissions()
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { ... }
}
refreshIcon()
```

The polling `Timer` that watches for a *granted* permission is created **only inside the
`!interceptor.arm()` branch** — i.e., only when the app starts up unarmed. If `arm()` succeeds at
launch (the common case — README says both grants are already in place on the dev machine), no
timer is ever created, and nothing in the codebase subsequently re-checks `Permissions.allGranted`.

`PasteInterceptor.isArmed` (`PasteInterceptor.swift:34`) is a `private(set)` flag that is set `true`
in `arm()` and only ever set back to `false` in `disarm()` (`PasteInterceptor.swift:65-78`), which
runs exactly once, at quit (`main.swift:143-146`). There is no code path that flips it back to
`false` in response to a TCC grant being revoked while the app is running.

The tap-callback's own permission-adjacent handling (`PasteInterceptor.swift:86-89`) only reacts to
`.tapDisabledByTimeout` / `.tapDisabledByUserInput` by blindly calling `CGEvent.tapEnable(tap:
enable: true)` again — it does not verify the underlying TCC grant is still valid before doing so.
If Accessibility or Input Monitoring is revoked via System Settings while PasteGuard is running, the
most likely outcome is: the tap silently stops delivering real key events (or macOS re-disables it
on the very next event, in a loop), `isArmed` stays `true`, `refreshIcon()` is never called again to
reflect the change, and **the menubar keeps showing the solid "guarding" shield** —
(`main.swift:41-47`) — while nothing is actually being scanned.

This is precisely the "dangerous for a security tool" scenario the audit brief names: a permission
revoked after launch fails silently rather than surfacing.

**Fix:** replace the one-shot `permissionTimer` with a low-frequency (e.g. every 10–15s, or on
`applicationDidBecomeActive`/`NSWorkspace` app-switch notifications to avoid needless polling)
`Permissions.allGranted` re-check for the whole app lifetime, not just the pre-arm window. On a
transition from granted → revoked: call `interceptor.disarm()`, flip the icon to the slashed-shield
state immediately, and — given this is a security tool — consider a one-time system notification
(`NSUserNotification`/`UNUserNotificationCenter`) the first time this happens, since a user who
revoked the permission by accident (or macOS did it after an update, which does happen) may not be
looking at the menu bar at that moment.

### 3.2 Browser detection fails silently, indistinguishably from "correctly not a surface" (Medium) — **Fixed**
Fixed by 3.1's global re-poll-and-disarm-visibly fix, exactly as the audit called out it would be:
an `AXIsProcessTrusted()` loss now surfaces via the same permission-revoked alert and icon change
rather than silently degrading to untouched pass-through.


`AISurfaces.swift:70-94`, `focusedWindowTitle(for:)`:

```swift
guard AXIsProcessTrusted() else { return nil }
```

If Accessibility trust is lost, this returns `nil` for *every* browser paste, which propagates up
through `currentDestination()` returning `nil` (`AISurfaces.swift:58-63`) and the tap passing the
keystroke through untouched (`PasteInterceptor.swift:122-124`). This is the same class of bug as 3.1
but narrower: even if 3.1 were fixed for the *native-app* case, browser-based AI surfaces have a
second, independent silent-failure path tied to the same permission. A fix to 3.1 (re-polling
`Permissions.allGranted` and disarming visibly) would also close this, since `AXIsProcessTrusted()`
loss is exactly what `Permissions.hasAccessibility` tracks (`Permissions.swift:17-19`) — but it's
worth calling out separately because the *symptom* here (an ordinary-looking pass-through paste into
Chrome) is indistinguishable from "this tab correctly wasn't recognized as an AI site," which is
the expected, desired behavior 95% of the time. There is no way, short of 3.1's global fix, for the
user to tell "my browser paste to Claude.ai wasn't flagged because Accessibility broke" from "my
browser paste wasn't flagged because it correctly wasn't sensitive."

### 3.3 Audit-log write failure is invisible but correctly non-blocking (Low / positive finding)
`AuditLog.swift:66-70` — a failed write is `NSLog`'d only (Console.app, not user-facing) and does
not affect the paste decision. Given the log's job is forensic/compliance record-keeping rather than
runtime protection, "never let a logging failure change or block behavior the user is waiting on" is
the right call. Flagging only because a persistent, repeated audit-write failure (e.g. disk full,
permissions issue on `~/Library/Application Support/PasteGuard/`) would currently have zero
user-visible signal at all — worth a "Reveal Audit Log" menu item disabling itself or showing a
warning badge if the file hasn't been written to in an implausibly long time, but this is minor
relative to 3.1/3.2.

### 3.4 Single-resolution guarantee on the decision panel (positive finding)
`DecisionPanel.swift:169-176`, the `finished` guard plus `windowWillClose` calling `finish(.cancel)`
(`DecisionPanel.swift:165-167`), together guarantee the panel's completion handler fires exactly
once regardless of how the window closes (button, Esc, red-close-button-equivalent, or losing focus
in a way that triggers close). This directly prevents the specific failure mode the code comment
calls out — `isPresenting` getting stuck `true` and silently disabling all future protection. Good,
deliberate defensive engineering; no fix needed.

---

## 4. Accessibility

### 4.1 `.appFont` / text-scale is consistently applied (positive finding)
Grep across `Sources/` for anything bypassing the new helper:

```
$ grep -rn "NSFont.systemFont\|NSFont(name" Sources/
Sources/Support.swift:138:        return .systemFont(ofSize: style.basePointSize * scale, weight: weight ?? style.defaultWeight)
```

The only hit is the helper's own implementation. `DecisionPanel.swift` and `SettingsWindow.swift`
both route every label/button through `.app(_:weight:)` (`DecisionPanel.swift:73-76,116-121,129-138`;
`SettingsWindow.swift:68,94,109`). No raw point sizes or hardcoded `NSFont` calls escaped the
refactor. This is a clean pass.

### 4.2 Severity is never color-only (positive finding)
`findingRow` (`DecisionPanel.swift:115-127`) pairs the color dot with an explicit text label
("Critical"/"High"/"Medium", via `Severity.label`) on every row — satisfies the "don't convey
information by color alone" accessibility principle without needing to be asked to.

### 4.3 Text Size ceiling is modest for a security-critical panel (Low)
`TextSizeSetting.scaleFactor` (`Support.swift:90-97`) tops out at `.extraLarge = 1.3`. For a panel
whose entire job is being read and understood correctly under time pressure, 1.3× over a 12pt body
baseline (~15.6pt) is a fairly conservative ceiling next to macOS's own Dynamic Type range. Not a
bug, just worth a note if low-vision users are an explicit target for this tool given its security
positioning.

### 4.4 No accessibility identifiers on decision-panel buttons for automated verification (Low) — **Fixed**
Cheap alongside the other `DecisionPanel` changes: `setAccessibilityIdentifier` added to all three
decision buttons (`cancel`, `paste-original`, `redact-and-paste`) plus the new preview toggle and
preview text field.


`button(_:action:key:)` (`DecisionPanel.swift:140-145`) sets a title but no
`setAccessibilityIdentifier`/`accessibilityLabel`. VoiceOver will still read the title text
correctly (NSButton's default), so this isn't a screen-reader defect — but it means there is
currently no stable hook for UI-level automated testing of this panel (relevant given the project
has no UI test target at all, only the Foundation-only detector suite in `Tests/main.swift`).

---

## 5. Functional Bugs / Wiring Check

Grepped for the usual smells:

```
$ grep -rn "TODO\|FIXME\|unimplemented\|not implemented" Sources/
(no matches)
$ grep -rn "{ }\|{}" Sources/
(no matches)
```

Traced every button/control action by hand:
- `DecisionPanel` — `redactTapped`/`allowTapped`/`cancelTapped` all call `finish(_:)` with the
  correct decision (`DecisionPanel.swift:158-160`); wired correctly.
- `SettingsWindow` — `appearanceChanged`/`textSizeChanged` both update the backing `UserDefaults`
  enum and refresh button states (`SettingsWindow.swift:120-130`); wired correctly. (Minor
  inefficiency, not a bug: matching the sender via `first(where: { $0.value === sender })` over a
  small fixed dictionary is fine at this scale.)
- `AppDelegate` menu actions (`openAccessibility`, `openInputMonitoring`, `scanClipboard`,
  `openSettings`, `revealLog`, `quit`) all call through to real implementations; none are stubs.

**One layout item worth a real (visual) spot-check, not confirmable from source alone:**
`DecisionPanel.swift:105-111` mixes `NSStackView`'s automatic arranged-subview constraints with one
manual constraint pinning the *inner* `buttons` stack's trailing edge to the outer `stack`'s
trailing edge minus 22pt:
```swift
buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -22),
```
`buttons` is itself an arranged subview of `stack`, which already manages its arranged subviews'
horizontal extent via `stack.alignment = .leading` (no explicit width) — adding a second, explicit
trailing pin on the same view NSStackView is simultaneously laying out can produce an
over-constrained or unexpectedly-clipped button row, particularly at the `.extraLarge` text scale
where button `fittingSize` grows. This cannot be confirmed without actually rendering the panel;
flagged as the top item for a real (non-automated, human-driven) visual check before shipping past
POC.

---

## 6. Readiness Gaps for the Unverified Live-Interception Path

The README states plainly: "Live interception — actually catching a real ⌘V into an AI app — has
not yet been exercised end to end." Reading the interception path top to bottom, here is what
plausibly explains that, concretely, and what to verify first.

### 6.1 Bundle-ID allowlist fragility (High) — **Verified, no change needed**
Checked directly against the currently installed Cursor.app on this machine:
`com.todesktop.230313mzl4w4u92` is still the correct bundle ID
(`/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /Applications/Cursor.app/Contents/Info.plist`).
No drift found; the fragility concern itself (a repackage could change it) stands as documented and
should be re-checked again after Cursor's next major update.


`AISurfaces.swift:17-26`, `nativeBundleIDs`, includes:
```swift
"com.todesktop.230313mzl4w4u92",   // Cursor
```
This is a [todesktop](https://todesktop.com)-generated identifier, not a stable vendor-assigned
bundle ID — todesktop mints a project-specific ID at build-packaging time, and Electron-shell apps
built on it have been known to change this string across major app updates when the app is
repackaged. Every other entry in the list (`com.anthropic.claudefordesktop`, `com.openai.chat`,
etc.) is a normal reverse-DNS ID under the vendor's own domain and much less likely to drift. Cursor
specifically is the one entry in this list actually worth re-verifying against the currently
installed build before relying on it.

### 6.2 Browser detection: title-substring matching + a timing assumption (High) — **Skipped**
Not addressed in this pass. Both risk vectors described (title truncation, AX-read timing races) need
live, human-driven verification against real site behavior to confirm and fix correctly — exactly
what the audit's own section 6.5 prescribes as the next step, not a code change that can be made
correctly from source alone. A speculative code change here (e.g. widening markers, adding a retry)
risks papering over the real failure mode without confirming it, or introducing new race conditions
of its own inside the hard-deadline tap callback.


`AISurfaces.swift:44-47,58-63`: browser destination detection depends on the **focused window's AX
title containing a lowercase marker string** ("claude", "chatgpt", etc.) at the exact instant ⌘V is
pressed. Two concrete risk vectors:
- **Title truncation/customization.** Some sites set a generic or truncated title after SPA
  navigation (e.g. a mid-conversation title update that briefly reads just "New chat" before the
  async rename lands); a paste that lands in that window is a false negative — the exact opposite of
  what the tool exists to prevent, and silent (nothing tells the user their paste wasn't checked).
- **AX read timing.** `focusedWindowTitle` reads `kAXFocusedWindowAttribute` /
  `kAXTitleAttribute` synchronously inside the tap callback (`AISurfaces.swift:74-91`), which itself
  runs inside a hard-deadline `CGEventTap` callback. If a browser is slow to update its AX title
  (common right after a tab switch or page load), the read can return a stale or empty title in the
  narrow window right after focus changes — a race between "user just switched to the AI tab" and
  "AX attribute finished updating," which is exactly the kind of timing assumption that would produce
  intermittent, hard-to-reproduce misses in real testing.

### 6.3 Terminal AI agents are entirely unrecognized — already confirmed failing (High, but already known) — **Fixed**
Added `com.apple.Terminal`, `com.googlecode.iterm2`, `com.github.wez.wezterm`, `io.alacritty`, and
`co.zeit.hyper` to `AISurfaces.nativeBundleIDs` (`Sources/AISurfaces.swift`), matching the audit's
own recommended scope: the whole terminal treated as a surface, same as Warp already was, without
the finer per-CLI-tool distinction a browser gets. This is the single highest-value fix in the
"what to verify first" list (6.5 #1) and directly closes the already-reproduced leak the README
documents for Claude Code / Aider pastes.


Neither `nativeBundleIDs` nor `browserBundleIDs` includes any terminal emulator, and the README's own
"Known gaps" section states this was tested live: a real key pasted into a Claude Code session in
this same project "wasn't caught," with the pattern independently confirmed fine via the detector
directly — i.e., the detection *logic* is sound, and the miss is purely a scoping gap in
`AISurfaces`. This is the most concrete, already-reproduced evidence of the exact fragility the audit
was asked to assess, and per the README it's arguably the single biggest real-world leak surface for
this app's likely (developer) audience — ahead of screenshots.

### 6.4 Synthetic-paste re-injection timing (Medium)
`PasteInterceptor.swift:184-202`: after a decision, the destination app is reactivated, then after a
150ms delay the frontmost app is re-verified before the synthetic ⌘V is sent
(`PasteInterceptor.swift:189-193`), and 450ms after that the original clipboard is restored
(`PasteInterceptor.swift:198-201`). These are reasonable, conservative constants for a healthy
system, and the design is explicitly defensive (bypass marker checked first with no time window at
all; the `expectingSyntheticPasteUntil` 300ms fallback is explicitly documented as a rare-case
backstop, not the primary mechanism — `PasteInterceptor.swift:20-27`). The scenario worth verifying
under load: this synthetic paste is injected via the same kind of event (`CGEvent`
`keyboardEventSource`) that the tap intercepts, at a time (`tapDisabledByTimeout` conditions —
i.e., precisely when the *system* is under load) that is the one case most likely to also delay this
re-injection past its own fallback window. Low probability, worth a load-test rather than a code fix.

### 6.5 What to verify first, concretely
1. **Terminal-agent scoping (6.3)** — already confirmed broken; the fastest, highest-value fix
   available (add terminal-emulator bundle IDs to a recognized-surface list, even without the finer
   per-CLI-tool distinction a browser gets).
2. **Permission-revocation monitoring (3.1)** — before any live-interception claim is trusted at
   all, since a silent fail-safe failure undermines every other verification.
3. **Bundle-ID / title-marker accuracy against currently-installed versions (6.1, 6.2)** — a
   one-time manual pass, ⌘V-ing into each of the 8 native apps and representative tabs for each of
   the 10 web markers, confirming both still match today's shipped builds.
4. **Under-load behavior (6.4)** — trigger `tapDisabledByTimeout` deliberately (e.g. a CPU-bound
   background task) and confirm both the tap re-arms (already handled,
   `PasteInterceptor.swift:86-89`) and a subsequent redact-and-paste still lands correctly within the
   synthetic-paste timing windows.

---

## Summary of fixes by effort (for prioritization)

**Small, high-value (do before calling live interception "verified"):**
- Re-poll `Permissions.allGranted` for the app's full lifetime, not just pre-arm (3.1)
- Add terminal-emulator bundle IDs to the recognized-surface list (6.3)
- Re-verify Cursor's todesktop bundle ID against the current build (6.1)

**Small, UX-value:**
- Show a redacted preview inside `DecisionPanel` itself, not just the debug scan path (1.1)
- Add an About section (version + the network-verification claim) to Settings (2.1, 2.2)
- Visually distinguish "Paste Original" when a critical finding is present (1.3)

**Larger, roadmap-appropriate (already tracked in README's Known Gaps, correctly deferred):**
- Per-pattern false-positive suppression (1.2)
- Policy layer / allowlists
