# Notifications redesign + Settings scroll-spy — Design

Date: 2026-09-02
Branch / build tag: `notif-redesign-scrollspy`

## Goal

Two independent UI improvements requested from screenshots:

1. **Notifications** — make the notifications in the app's menus look modern, immediately
   recognizable, and organized. Applies to **all three** notification surfaces so they stay
   consistent.
2. **Settings scroll-spy** — as the user scrolls the Preferences detail pane, the left
   sidebar highlight should follow the section currently in view (currently only the
   reverse — click sidebar → scroll — exists).

Verification is a tagged Debug build the user dogfoods. No second-model review unless the
user opts in.

---

## Part A — Notifications redesign

### A.0 Decisions

- **Organization:** time buckets (`Today` / `Yesterday` / `Earlier`), newest-first within
  each bucket. Unread notifications are **emphasized in place** and do **not** reorder when
  they become read (no jumping).
- **Unread emphasis:** soft accent-tinted row background (~7% accent), accent-colored
  title, and a small filled accent dot next to the timestamp.
- **Timestamps:** relative ("2m", "1h", "Yesterday"); absolute time moves to the tooltip.
- **Leading type-icon chip:** a rounded tinted square holding an SF Symbol derived from the
  notification's shape/action (completion → `checkmark.circle.fill`, reply-shaped → a reply
  symbol, otherwise `bell.fill`).

### A.1 Shared logic (single source of truth)

The repo's shared-behavior policy requires one implementation reused across every surface,
not three copies. New file under the shared notifications module (co-located with
`TerminalNotification`):

- `NotificationGrouping` — pure function `group(_ notifications:) -> [NotificationGroup]`
  where `NotificationGroup { id: Bucket, title: String, notifications: [TerminalNotification] }`.
  Buckets: `.today`, `.yesterday`, `.earlier`, computed from `createdAt` against the user's
  calendar. Input order (newest-first) is preserved within each bucket. Pure and
  `Calendar`-injectable so it is unit-testable without touching "now".
- `NotificationPresentation` (or free functions):
  - `categorySymbolName(for:) -> String` — SF Symbol for the leading chip.
  - `relativeTimestamp(for:relativeTo:) -> String` — short relative string, localized.
  - `absoluteTimestamp(for:) -> String` — for tooltips (existing `.formatted` shape).

All three surfaces consume these helpers.

### A.2 Surface 1 — Titlebar popover (`NotificationsPopoverView` + `NotificationPopoverRow`)

`Sources/Update/UpdateTitlebarAccessory.swift`, `Sources/Update/NotificationPopoverRow.swift`.

- `content` builds groups via `NotificationGrouping` and renders, per group, a **sticky-ish
  group header** (uppercase secondary caption + per-group count) followed by the group's
  rows. Keep the existing `LazyVStack` + snapshot-boundary discipline (`.equatable()`, no
  store reads below the list boundary — issue #2586/#5794). Group headers are cheap value
  views.
- `NotificationPopoverRow` redesign, preserving all existing behavior (hover clear button,
  context menu, accessibility identifiers/actions, key-view participation, `Equatable`
  snapshot rule):
  - Add leading **icon chip** (rounded tinted square, ~28pt) using `categorySymbolName`.
  - Replace the 2.5pt hard accent bar with **tinted row background** for unread
    (`cmuxAccentColor().opacity(~0.07)`) behind the existing hover tint, + a **filled accent
    dot** beside the relative timestamp. Read rows: no tint, hollow/no dot.
  - Title in accent color when unread, primary when read.
  - Timestamp becomes relative; full date/time moves to `help`/tooltip.
  - Row height may grow slightly to fit the chip; keep the fixed-min-height approach.
- The row's `Equatable ==` already compares `notification` + `workspaceTitle`; relative
  timestamp is derived from `notification.createdAt`, so no new stored inputs are needed.
  (Relative strings drift over time, but the popover is short-lived; recompute on open.)

### A.3 Surface 2 — In-app Notifications page (`NotificationsPage` + `NotificationRow`)

`Sources/NotificationsPage.swift`.

- `notificationsList` groups via `NotificationGrouping`; render group headers + rows in the
  existing `LazyVStack` (keep `.equatable()` per-row). Preserve focus handling
  (`focusedNotificationId`, default-action modifier) — the first focusable row stays the
  first notification overall.
- `NotificationRow` gets the same modern treatment as the popover row (icon chip, tinted
  unread background on the existing rounded card, accent title, relative time, filled dot).
  Keep the rounded `controlBackground` card; unread cards get the accent tint blended in.
- Keep the empty / unread-indicator / clear-all / jump-to-latest states unchanged.

### A.4 Surface 3 — Menu-bar dropdown (`MenuBarExtraController`)

`Sources/App/MenuBarExtraController.swift`, `MenuBarNotificationLineFormatter`.

- Native `NSMenu`, so no SwiftUI: apply the **same grouping** by inserting disabled
  section-header items (`Today` / `Yesterday` / `Earlier`) between runs of notifications,
  driven by `NotificationGrouping` over the `recentNotifications` snapshot (still capped at
  the existing inline limit).
- `MenuBarNotificationLineFormatter` uses `relativeTimestamp` for the attributed line's time
  and keeps the unread bullet. Tooltip keeps the absolute time.
- Header items are non-selectable (`isEnabled = false`), tracked alongside `notificationItems`
  so they are removed/rebuilt together.

### A.5 Localization

New user-facing strings — bucket titles (`Today`, `Yesterday`, `Earlier`), relative-time
units, any new accessibility labels — added to `Resources/Localizable.xcstrings` via
`String(localized:)`. These surfaces are macOS-only (no web catalog). A localization audit
is part of the handoff. Prefer the system's relative formatting
(`RelativeDateTimeFormatter` / `Date.FormatStyle`) where it yields correctly localized
short output; otherwise localize explicit keys.

### A.6 Notifications testing

- Unit tests for `NotificationGrouping`: fixed `Calendar` + fixed "now"; assert bucket
  assignment at boundaries (just-before/after midnight, 24h+), ordering preserved, empty
  buckets omitted.
- Unit test for `categorySymbolName` mapping per notification shape/action.
- Test wiring verified (`./scripts/lint-pbxproj-test-wiring.sh`) so new test files are not
  silently skipped.

---

## Part B — Settings scroll-spy

`Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Scene/SettingsWindowScene.swift`.

### B.1 Mechanism

- Add a named coordinate space on the detail `ScrollView` (e.g. `.coordinateSpace(name: "settingsScroll")`).
- Each rendered section already carries `.id(anchorID(for: section))`. Attach a lightweight
  `GeometryReader`-backed `background` (or overlay) to each section that publishes its top
  `minY` in the `settingsScroll` space through a `PreferenceKey`
  (`SettingsSectionOffsetsKey: [SettingsSectionID: CGFloat]`, reduce = merge).
- An `.onPreferenceChange(SettingsSectionOffsetsKey.self)` handler picks the **active
  section**: the last section whose top offset is `<= activationLine` (a small inset below
  the viewport top, e.g. 12pt). Update the sidebar highlight to that section.

### B.2 Updating the highlight without a scroll feedback loop

- The `List` selection getter reads `selectedSidebarEntryID`; its setter
  (`sidebarSelectionBinding`) posts a navigate→scroll. Scroll-spy must **not** go through the
  setter.
- Add `private func highlightSectionFromScroll(_ section:)` that writes `selectedSectionRaw`
  and `selectedSidebarEntryID = sectionEntryID(for: section)` **directly** (guarded so it
  only writes on an actual change — this also throttles the `@AppStorage` /
  `UserDefaults.didChangeNotification` writes to once per boundary crossing). No navigation
  notification is posted, so no scroll is triggered; the List highlight simply follows.

### B.3 Robustness

- **Post-click suppression:** clicking a sidebar row animates a programmatic scroll. Record
  `programmaticScrollUntil = Date() + ~0.4s` in `applyScrollNavigation` (and the `onAppear`
  restore). While `Date() < programmaticScrollUntil`, `onPreferenceChange` ignores updates so
  spy does not fight the animation or land on an intermediate section.
- **Hysteresis:** only switch to a new section when its top crosses the activation line by a
  small margin, avoiding flicker between two sections at the boundary.
- **Search off:** while `isSearching` is true the sidebar is a filtered result list, not a
  continuous section map — disable spy (return early) so it doesn't fight search selection.
- **Deep search-hit selection:** spy sets the section header row. It does not attempt to
  track individual setting rows.

### B.4 Scroll-spy testing

- Prefer a pure helper `activeSection(offsets:activationLine:current:hysteresis:) -> SettingsSectionID?`
  extracted from the handler, unit-tested with synthetic offset dictionaries (boundary,
  hysteresis, empty). UI-driving the real scroll in a unit test is brittle; the pure
  selection function is the behavior worth covering.

### B.5 Non-goals

- No change to section content, ordering, or the click→scroll path.
- Not adopting macOS-15-only scroll APIs (`onScrollGeometryChange`); the PreferenceKey
  approach works across supported macOS versions (reporters may be on older macOS).

---

## Approaches considered (and rejected)

- **Notifications organization "New group on top"** — rejected: rows visibly jump when read
  and recency is duplicated. Time buckets with in-place emphasis is the standard, stable
  model.
- **Scroll-spy via AppKit `NSScrollView` contentOffset observation** — rejected: heavier,
  more bridging code, and the pane is SwiftUI; the PreferenceKey path is sufficient.
- **Scroll-spy via `onScrollGeometryChange`** — rejected: macOS 15+ only.

## Files touched (anticipated)

- `Sources/TerminalNotification.swift` area — new `NotificationGrouping` / presentation
  helpers (new file(s) in the same module).
- `Sources/Update/NotificationPopoverRow.swift`, `Sources/Update/UpdateTitlebarAccessory.swift`.
- `Sources/NotificationsPage.swift`.
- `Sources/App/MenuBarExtraController.swift` (+ `MenuBarNotificationLineFormatter`).
- `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Scene/SettingsWindowScene.swift`.
- `Resources/Localizable.xcstrings`.
- New test files under `cmuxTests/` (+ pbxproj wiring) and/or the settings package tests.

## Out of scope

- Notification delivery, sound, phone-forwarding logic — untouched.
- The three surfaces' non-list states (empty, jump-to-latest, clear-all) keep current
  behavior; only visual row/grouping treatment changes.
