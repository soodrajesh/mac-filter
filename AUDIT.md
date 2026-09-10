# Audit — 2026-09-10

## Build
`./build.sh` passes clean: universal binary (arm64 + x86_64), signed with the
real Developer ID Application identity in the keychain (hardened runtime on),
installed to `/Applications/PasteGuard.app`. A standalone `swiftc -O
-warnings-as-errors` compile of all of `Sources/*.swift` also produced **zero
warnings**.

## Tests
`./test.sh` — **50/50 passing** (Checksums, Credentials, False positives,
Personal data, Redaction, Performance). No failures, nothing needed fixing.

## Audit findings

### Crashes / force-unwraps / TODOs
- No `TODO`/`FIXME`/`XXX` markers anywhere in `Sources/` or `Tests/`.
- No force-unwraps (`!`) in `Sources/` except one `try!
  NSRegularExpression(pattern:...)` in `Detectors.swift` on a hardcoded,
  compile-time-constant regex — standard practice, and covered by the 50
  passing tests (a bad pattern would fail every test run, not just crash at
  runtime). `AISurfaces.swift` explicitly avoids a force-cast on the
  AXUIElement CF type in favor of a `CFGetTypeID` check + `unsafeBitCast`,
  with a comment explaining why. No fixes needed here — the codebase is
  already careful about this.

### App icon / assets
- App icon is generated at build time from an SF Symbol
  (`shield.lefthalf.filled`) via `build.sh`, not checked into git (correctly
  gitignored). No missing/placeholder icon states found — this is a menubar
  accessory app with a single status-item icon, no Dock icon set variants
  needed.
- Status bar icon toggles between `shield.lefthalf.filled` (armed) and
  `shield.slash` (not armed) — both real SF Symbols, used consistently. Only
  one icon call site in the whole codebase (`main.swift`); no mix of SF
  Symbols and custom image assets.

### Entitlements
- `.entitlements` file exists, no App Sandbox (deliberate, documented inline —
  the app needs unrestricted clipboard/Accessibility/event-tap access that
  sandboxing would break), hardened runtime exemptions all explicitly `false`.
  This is correct for what the app does.
- **Found and left as an open item (not fixed):** `Info.plist` declares
  `NSAppleEventsUsageDescription` ("PasteGuard reads the frontmost window's
  title..."), but nothing in `Sources/` uses Apple Events, `osascript`, or
  `NSAppleScript` — window-title reading (`AISurfaces.swift`) goes through the
  Accessibility API (`AXUIElementCopyAttributeValue`) only, which is already
  covered by the Accessibility TCC permission. The Apple Events usage string
  is unused and can likely be removed from `build.sh`'s embedded Info.plist.
  Left unfixed since removing an Info.plist key is a product-facing
  permissions change, out of scope for a build/audit pass.
- Accessibility and Input Monitoring are correctly handled as TCC permissions
  (`Permissions.swift`, `AXIsProcessTrusted` / `IOHIDCheckAccess`), not
  entitlement keys — that's the correct approach since neither is an
  entitlement for a non-sandboxed app.

### Dead code / unused files
- None found. `git status` is clean, `git ls-files` shows only files actually
  used by the build/test/signing pipeline. `PasteGuard.app/` and `*.dmg` are
  correctly gitignored build output, not tracked.

### Version currency
- `CFBundleShortVersionString` 0.1 / `CFBundleVersion` 1 (set in `build.sh`),
  matches the shipped `PasteGuard-0.1.dmg` filename — internally consistent.
- No git tags exist yet; 8 commits total, most recent
  (`5b76595 build: ship signed, notarized universal DMGs`) post-dates two
  commits that fixed real signing bugs. This reads as genuinely early-stage
  (a working POC that has iterated quickly on its signing pipeline), not a
  mature app that's just under-versioned — v0.1 is an accurate label.
- **Doc drift (fixed):** README said "Detection core covered by 49 tests" in
  two places; actual count is now 50. Updated both to match.
- **Doc drift (open, not fixed):** README's "Known gaps" section still lists
  "Self-signed identity, not Developer ID" as a gap, but `build.sh` now signs
  with a real Developer ID Application identity when present (confirmed
  during this audit's build run) and `notarize.sh` exists. That gap entry may
  be stale — left for the maintainer to confirm notarization has actually
  been exercised end-to-end before rewriting the claim.

## Fixes made
1. README.md — corrected stale "49 tests" → "50 tests" in two places (Status
   section and Known gaps section).

No source code changes were needed — the codebase built clean, warning-free,
and all tests passed with no fixes required.

## Open issues (not fixed, flagged for follow-up)
1. `NSAppleEventsUsageDescription` in the `Info.plist` `build.sh` generates is
   unused — no Apple Events API is called anywhere in `Sources/`.
2. README "Known gaps" list still says the app is self-signed only; the build
   pipeline has since moved to real Developer ID signing + notarization
   tooling. Worth confirming notarization has actually been run end-to-end,
   then updating that section.
3. Per the app's own README "Known gaps" (not re-verified independently in
   this pass, just noted as still open per the project's own docs): live
   ⌘V interception hasn't been exercised end-to-end in every surface,
   terminal-based AI agents (Claude Code, Aider, etc.) aren't a recognized
   paste destination, drag-and-drop/right-click paste bypass the tap, and
   screenshots/images aren't inspected. These are scoping decisions for a
   POC, not bugs.

## Current version
**0.1** (`CFBundleShortVersionString`), build 1. Matches `PasteGuard-0.1.dmg`.
Genuinely early-stage — accurate versioning, not under-versioned.
