# C11 `settings`: Settings and devices for cmux-next iOS

Status: implemented on `feat-cmux-next-ios-c11-settings` (base `feat-cmux-next-ios`), 2026-10-06.
Binding: PLAN.md (this directory, rules section 4), a1-shell.md (2.7 Settings form, 1.4, 1.6, 1.17),
c16-platform.md (Settings links, consent toggle), c10-onboarding.md (Replay tour), a3-link.md
(`PathBadge`), OWNERSHIP-PRINCIPLES.md. Parity reference (read-only): `repo/Packages/iOS/CmuxMobileShellUI`
(`MobileSettingsView`, account section, delete-account failure kinds, legal and support links).

## 1. Information architecture

One SwiftUI `Form` (low frequency, a1-shell.md 2.7), sections in frequency order, each deeper page a
push. Root:

| Section | Rows | Owner of truth |
| --- | --- | --- |
| Account | profile (name, email), Team picker (when the user has teams), Sign Out | Stack Auth via `AuthCoordinator` |
| Devices & Macs | this device first, then Macs, then other devices; each row pushes Device detail | account device registry (`DeviceRegistry`, B6 owner `UserDO`/`PairingDO`) |
| Preferences | Terminal >, Notifications >, Privacy > | this device (client state), notification filter mirrored to C7 |
| Help | What's New, Diagnostics, Plans (flag), Demo Content (demo only), Replay Welcome Tour | C16, C10 |
| About | version (DEV tag), Privacy Policy, Terms of Service, Support, Acknowledgements | compiled in |
| Developer (DEBUG) | Feature Sources and Flags (A1) | client |
| Danger zone | Delete Account | backend `DELETE /api/account` through `AuthCoordinator.deleteAccount()` |

Existing hooks stay: `links:` (C16 rows, rendered in Help in the given order) and `replayTour:` (C10).

### 1.1 Account

- Profile row shows display name and email (email selectable).
- Team: a `Picker` over `AccountSnapshot.teams`; choosing calls `selectTeam(id:)`, which persists on Stack
  before the local projection changes (kept code). While the request runs the picker is disabled and shows
  progress; a failure reverts to the server value and shows an inline footer error.
- Sign Out: confirmation dialog (A1 behavior).
- Delete Account (last section, destructive): alert with the shipping copy ("This permanently deletes your
  cmux account and cmux data. You will be signed out on this device."). Success signs out through the
  normal sign-out owner (so `beforeSignOut` revokes the install). Failures map to `AccountDeletionFailure`
  (generic, connection, unauthorized, stackDeleteIncomplete, serverCleanupIncomplete, timedOut, unknown),
  same copy as the shipping app; unauthorized and serverCleanupIncomplete sign out after the user
  acknowledges.

Seam: `AccountControlling` (MainActor) in `CmuxiOSSettingsCore`: `snapshot`, `updates()`,
`selectTeam(_:)`, `deleteAccount()`, `signOut()`. The real `StackAccountController` lives in the app
target over `StackAuthGate` (observes `currentUser`, `availableTeams`, `selectedTeamID`,
`isSelectingTeam` with `withObservationTracking`, no polling) and maps runtime errors into
`AccountDeletionFailure`. `MockAccountController` for previews and tests.

### 1.2 Devices & Macs (parity 1.6, a1-shell.md "Computers list with routes and ping")

`DeviceListProjection` (pure) turns the registry snapshot into sections: this device, Macs (trusted then
discovered), other devices; revoked devices hidden; names sorted with localized compare. Each row: platform
glyph, name, status line ("This device", "Paired · seen 5 min ago", "Not paired"), and when the device has
a live link, the path and RTT ("Direct · 12 ms", "Relay · 140 ms").

Device detail: name (rename), platform, trust, last seen (relative and absolute), connection (path kind,
carrier, RTT; "Not connected" otherwise), Remove (revoke) with a destructive confirmation. This device
cannot be removed (the row says "Sign out to remove this device", matching the mock owner's refusal).
Rename validation is pure (`DeviceNameRule`: trimmed, 1 to 64 characters, no control characters).
Intents carry a fresh `IntentKey` per user action; a refused receipt or `FeatureSourceError.offline`
shows inline; nothing queues while the registry is not live (U5).

Transport diagnostics: `LinkDiagnosticsSource` streams `[DeviceRecord.ID: PathBadge]` (A3's value type,
`CmuxLink` package). The owner of a link is whoever holds the `CmuxLink` for that host (B5/D1); they fill
`AppContainer.linkDiagnosticsFactory`. Until then `MockLinkDiagnosticsSource` serves direct 12 ms for the
Mac Studio and relay 140 ms for the Mac mini. Settings subscribes only while visible (`.task`).

### 1.3 Terminal

`TerminalPreferences` (Codable, client state of this device, never synced; key
`dev.cmux.ios.next.terminal.v1`):

| Setting | Values | Default | Renderer effect |
| --- | --- | --- | --- |
| theme | Match Mac, Ghostty Default, Monokai, Paper (light), Ink (dark) | Match Mac | `ThemeInput` from `CmuxTheme`; Match Mac keeps the theme the host sent |
| font family | Default (JetBrains Mono, embedded in Ghostty), Menlo, Courier New | Default | `font-family` |
| font size | 9 to 24 pt, step 1 | 13 | `TerminalFontSizing.baseSize` |
| follow Dynamic Type | on/off | on | `GhosttyTerminalView.followsDynamicType` |
| cursor | block, bar, underline; blink on/off | block, off | `cursor-style`, `cursor-style-blink` |
| key bar | ordered subset of the key bar keys, reorder and toggle, Reset | A2 default bar | `ios.terminal.accessoryKeys` |

Only fonts installed on iOS (or embedded) are offered, so the choice always renders. The page has a live
preview (prompt and ANSI colors in the selected theme, font and cursor).

Feeding A2: `TerminalPreferences.appearance` produces a `TerminalAppearance` (new, in
`CmuxTerminalRenderCore`: theme, font family, base size, follows Dynamic Type, cursor style and blink, key
bar ids). `TerminalGhosttyConfig` gains `fontFamily` and `cursorStyle` (emitted only when set, so existing
configs are byte-identical). `TerminalViewController` takes an optional `TerminalAppearanceProviding`
(the app's `TerminalPreferencesStore`), applies the current appearance on load and follows
`appearanceUpdates()` while visible, so a change in Settings reaches an open terminal in the Hosts tab.

### 1.4 Notifications

Per-kind toggles: Permission requests, Questions, Plan approvals, Finished, Terminal alerts (bell and
`cmux.terminal`), plus Sound and Time-Sensitive. The system authorization state heads the page
(Allowed, Off with an "Open iOS Settings" button, Not determined with "Turn On"). Stored on device
(`dev.cmux.ios.next.notifications.v1`). The server decides what to push, so the preference must reach the
push owner: `NotificationPreferencesSink` is the C7 seam (`apply(_:key:)` answering an `IntentReceipt`);
C7 sends it to B1's per-device push filter and also filters in the Notification Service extension. Until
C7 lands the store keeps the local value and marks it "Saved on this iPhone".

### 1.5 Privacy

The crash-report and telemetry consent toggle moves here from C16's Diagnostics screen. Same key
(`UserDefaultsAnalyticsConsentProvider.telemetryKey`, default on), so an existing opt-out carries over
and `CrashReporter` keeps observing `UserDefaults.didChangeNotification`. Diagnostics shows the current
state and points to Settings > Privacy.

### 1.6 About

Version and build (with DEV tag), Privacy Policy, Terms of Service, Support email (shipping URLs), and
Acknowledgements (Ghostty, libssh2/SwiftNIO SSH as bundled, Sentry, Stack Auth; compiled list).

## 2. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSSettingsCore` (new) | preferences values and stores, device projection, rename rule, account seam and failure mapping policy, notification sink seam, link diagnostics seam, mocks | Foundation, Observation, FeatureKit, CmuxTheme, CmuxTerminalRenderCore, CmuxLink |
| `CmuxiOSShell/Settings` | the form, device detail, terminal, notifications, privacy, about pages | + SettingsCore |
| `CmuxiOSTerminal` | applies `TerminalAppearance` | + RenderCore (already) |
| `CmuxiOSApp` | `StackAccountController`, `SystemNotificationAuthorization`, slots `linkDiagnosticsFactory`, `notificationPreferencesSinkFactory` | |

SettingsCore has no UIKit so its tests also run with `swift test` on macOS through a scratch package.

## 3. Accessibility and localization

Every row is a standard `Form` control (VoiceOver labels from the control titles; device rows combine
glyph, name, status and path into one element with the path spoken as "Direct path, 12 milliseconds";
destructive actions confirmed). Dynamic Type only (no fixed fonts except the monospaced preview, which
scales with `relativeTo: .body`). Strings in the Shell catalog, en and ja translated, the other 19
languages `needs_review`.

## 4. Tests

Swift Testing in `CmuxiOSSettingsCoreTests`: preference defaults, Codable round trip, unknown and
corrupt stored data fall back to defaults, store persistence and update streams, appearance mapping
(theme choice to `ThemeInput`, Match Mac keeps nil, key bar ids), Ghostty config text for font family and
cursor, device projection (sections, order, revoked hidden, status), rename rule, deletion failure policy,
notification store and sink receipt, consent store over the shared key, mock account team switch and
deletion. A drift test in `CmuxiOSTerminalTests` checks the settings key ids equal `TerminalKeyBarKey`.

## 5. Not done here

- Real link diagnostics and notification sink: slots wait for B5/D1 and C7.
- Hidden computers and order (C5), Keep Mac Awake row placement (C16 stub stays DEV-only until B5).
- Erase all data on this device: needs a list of every lane's on-device store; follow-up after D3.
- Tagged build `nxc11`: not attempted (known blocked: dev backend VM, no fleet manifest, disk).
