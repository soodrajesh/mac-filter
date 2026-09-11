# Changelog

## 2026-09-11 (2)

- Fixed UX-AUDIT §1.2 (High): added a "Don't ask again for this, here" per-finding suppression checkbox, scoped to (finding kind × destination app), persisted in `UserDefaults` via new `SuppressionStore.swift`. All findings previously suppressed for an app now let the real paste through untouched (still audit-logged as "allowed (suppressed)"); non-suppressed findings still gate normally.

## 2026-09-11

- v2 UI refresh — modern colorful design system: tinted severity icon tiles in the decision panel, card-based finding list, green accent color, improved light mode.

## 2026-09-10

- Renamed from PasteGuard to MacFilter. New bundle identifier: com.rajeshsood.macfilter.
