# cmux-next windows: one window system

Lane 20 (Lawrence, 2026-10-02/03): "make settings a pane", "make sure new
windows have close button", "cmd w on the new window routes to the wrong
thing", then "one window system for every current and future window" and
"one background color for every surface".

## Why one system

Every bug of this lane had the same shape: each window was built by hand.
- Settings, Debug Settings (and likely the App Store) set the window
  background while AppKit installed the SwiftUI content view, which put the
  content above the titlebar and hid the traffic lights (fixed per window in
  74324ca921f, by order of calls).
- Cmd-W in a window of its own ran Close Tab on the main window behind it,
  because handlers resolve "the focused object" through the last main
  window (fixed by `StandaloneWindowRule`, 3cf3ecdc6c3, a rule keyed on
  "not a main window", not on what the window is).
- Debug Settings had its own Cmd-W override; popups have their own Cmd-W
  interception.
- Surfaces paint their backgrounds from different tokens
  (`Palette.windowBackground`, `utilityWindowBackground`, SwiftUI
  `SettingsStyle.background`, per-view fills), so the sidebar, panes, page
  tabs, titlebar and docks can differ.

A window is a kind. The kind decides chrome, background, close semantics and
what each shortcut means. Nothing else may decide those.

## Model

- `WindowKind` (CmuxNextDesign, `CaseIterable`): `main`, `settings`,
  `debugSettings`, `appStore`, `onboarding`, `onboardingGallery`,
  `browserPopup`, `devTools`, `pageInfo`, `terminalDebug`, `browserDebug`.
  Overlay panels (palette, hover cards, omnibox suggestions, notifications,
  appearance studio, tab group editor, drag ghosts, divider catchers,
  restart notice, update sheet) are not kinds: they are children of a
  window and resolve to their root window's kind.
- `WindowKind.traits`: style mask (always `.titled` + `.closable` for a
  kind with traffic lights; which of minimize/zoom show), whether it is a
  main window, `close: WindowCloseSemantics` (`.contentFirst` for main:
  Cmd-W closes the focused tab; `.window` for every other kind:
  `performClose`, so the delegate may decline, as with the close button).
- `WindowKit.install(_ window:, kind:, content:, scope:)` is the only way a
  window gets its content: it records the kind (`WindowKindRegistry`, weak,
  like `ThemeScopeRegistry`), enforces the traits, adopts the theme scope,
  sets the window background from the ONE background token, and only then
  sets `contentView`. Every window owner calls it; `WindowInvariants`
  faults on a visible app window without a kind (DEBUG).
- Root resolution: `WindowKindRegistry.root(of:)` walks
  `sheetParent ?? parent`; a sheet, palette or child panel acts as its root
  window's kind. A parentless Chromium page window is not a root of its own.

## One background token

`ThemeTokens.surfaceBackground` (the window background of the active theme
scope, honoring `background-opacity`) is the only background of: the
window (`WindowKit.install`), the sidebar, panes and the pane strip, page
tabs (Settings, Debug Settings, App Store), the titlebar and docks. Views
draw nothing of their own where they sit on it (clear), or draw exactly that
token. `utilityWindowBackground` and `SettingsStyle.background` go away or
become the same token. A test renders each surface kind with
`NSWindow.renderSnapshot()` and compares a background pixel with the token.

### One backdrop rule (Lawrence R31, coordinator 2026-10-03; landed)

Every window kind gets exactly one backdrop, the main window's: one
material plus the token as its tint at the theme's `background-opacity`
(`WindowBackdrop`). The main window's root draws it (`WindowSurfacePainting`);
every other kind gets it from `WindowKit.install`, which wraps the content in
a `WindowSurfaceView` (backdrop at the bottom, content above). With opacity
below 1 or blur on, the window itself is clear and every surface above the
backdrop (sidebar, panes, strips, titlebar, docks, page tabs incl. Settings
and App Store, web pages) is clear, never a semi-opaque fill of its own. At
opacity 1 they draw the token or stay clear. There are no tonal steps
(`appearance.tabBarBackground` and the sidebar step are gone; retired keys:
`SettingsSchema.retiredKeys`). `OneBackdropTests` walks every kind.

### Web theme (shared by every cmux web view)

`WebTheme` (CmuxNextDesign) is the one web theme, from the same tokens.
A cmux web view installs `WebTheme.bootstrapScript` at document start; it
defines `window.cmuxTheme.apply(payload)`, makes `html` paint
`var(--cmux-surface-background)` and keeps `body` transparent. The view runs
`WebTheme(tokens).applyScript` on load and on every theme change (the agent
pane does this in `AgentPaneTheme.script`). Payload:

```json
{
  "colorScheme": "dark",
  "variables": {
    "--cmux-surface-background": "rgba(30, 30, 46, 1.0)",
    "--cmux-surface-token": "rgba(30, 30, 46, 0.6)",
    "--cmux-elevated-background": "rgba(...)",
    "--cmux-text": "rgba(...)",
    "--cmux-text-secondary": "rgba(...)",
    "--cmux-text-tertiary": "rgba(...)",
    "--cmux-separator": "rgba(...) or transparent (appearance.borders none)",
    "--cmux-hover": "rgba(...)",
    "--cmux-selection": "rgba(...)"
  }
}
```

`--cmux-surface-background` is the page background: the opaque token in an
opaque window, `rgba(..., 0.0)` over a see-through window (the window's one
backdrop shows through). `--cmux-surface-token` is the token itself with its
opacity. A page listens to `cmux-theme` events (`detail` = payload) for live
changes. The React Settings page is transparent over it.

## One keyboard table

`WindowKeyTable.behavior(for: ActionID, in: WindowKind) -> WindowKeyBehavior`:
- `.run`: the action runs as today (main window focus).
- `.closeWindow`: close the root window (`performClose`).
- `.consume`: nothing runs, no beep (a sheet or panel over a standalone
  window got a close shortcut).
- `.disabled(reason)`: the menu item is off, a run is refused with the
  reason (destructive actions on main window content: tab, pane, workspace,
  screen, group, column, window targets).

Rows: `main` runs everything. Every other kind: close actions (catalog ids
whose last segment starts with `close`) are `.closeWindow`; app-level
actions (`quit*`, `newWindow`, `newIncognitoWindow`, `openSettings`,
`openDebugSettings`, `commandPalette`, `showHideAllWindows`, `about`,
`appStore.show`) are `.run`; destructive content actions are `.disabled`;
the rest `.run` against the last main window (macOS convention: Cmd-T in a
Settings window opens a tab in the main window). The table replaces
`StandaloneWindowRule` behind the same registry hook
(`ActionRegistry.keyWindowRoute`), so keyboard, menu bar and palette agree.

Test: `WindowKind.allCases` x every catalog action with a default shortcut
-> expected behavior, from an explicit per-kind expectation table in the
test. `Set(expectations.keys) == Set(WindowKind.allCases)`, so a new kind
fails the test until its row exists. The same test asserts every kind can
produce `debug.window_snapshot` and shows a visible close button above its
content.

## debug.window_snapshot (landed, fe8178428ee)

`debug.window_list` lists every app window (`NSApp.windows`, popover, panel
and sheet windows too): `id` (window number), `kind` (the kit kind, else
`popover`, `sheet`, `panel`, the `cmux.` identifier or the class name),
`title`, `frame`, `visible`, `parent`. `debug.window_snapshot` takes any of
those ids as `window`.

Renders a window's frame view through AppKit (`cacheDisplay`), no Screen
Recording grant. Differs from the screen: Metal layers (Ghostty terminal
surfaces, Chromium pages) render as their background; Liquid Glass and
visual effect views render without the blur of what is behind; child
windows (Chromium page windows, panels) are not included. Use
`read-screen` for terminal text.

## Migration

| Window | Owner | Today | After |
| --- | --- | --- | --- |
| main | `WindowController` | `ShellWindow`, `applyBackdrop` before content | `WindowKit.install(kind: .main)` |
| Settings fallback | `SettingsWindowController` | background before content (74324ca921f) | install(.settings) |
| Debug Settings fallback | `DebugSettingsWindowController` | same | install(.debugSettings) |
| App Store | `AppStoreWindowController` (becomes a page tab) | content before background | install(.appStore) until the page lands |
| onboarding, gallery | `OnboardingWindowController`, `OnboardingGalleryController` | hand-built | install(.onboarding / .onboardingGallery) |
| browser popup | `BrowserPopupPanel` | own Cmd-W interception (`popups.interceptKeyDown`) | install(.browserPopup); Cmd-W through the table |
| DevTools | `CEFDevToolsWindow` | hand-built | install(.devTools) |
| page info, terminal/browser debug | `PageInfoWindows`, `TerminalDebugWindow`, `BrowserDebugWindow` | hand-built | install(kind) |

Deleted: `StandaloneWindowRule` (its tests move to the table test), the
per-window background ordering in Settings/Debug Settings controllers,
`SettingsStyle.background` as a separate token, popups' private Cmd-W path.

## Transparency (after the token)

Settings > Appearance: window background opacity and blur, applied live,
through the Ghostty keys `background-opacity` and `background-blur` (cmux.json
override where Ghostty has none), one row each, docs, en + ja strings, tests.
They feed the same token, so every surface follows.
