# Apps to web (App Store page)

Owner request (user, 2026-10-21): "apps needs to move to web". Goal: the App Store is the
React page in `webviews/src/pages/apps` only. The SwiftUI store in
`CmuxNextApps/Store` goes away, with a thin AppKit host and a small native bridge.

## Where it was

- The React page exists (react-pages.md A1-A3) behind Debug Settings `apps.store.surface`,
  default `native` since hq-6d (2026-10-13). That decision listed these gaps: Hide/Show,
  update, grants, logs and icons. The daemon now serves grants, logs, `asset.get` and
  `hidden.set` (`cmux-tui-core/src/apps/store_panels.rs`, cx-hnmbt.13). Update shows the
  owner's `updates.list`, or the stale state when the owner does not have it.
- These gaps were still open:
  1. **Symbol icons.** A listing whose icon is an SF Symbol name drew initials, because the
     page must not draw Apple's symbols (coordinator Q5).

**No Features tab** (a500, extensibility-DESIGN.md): cmux's own features (49 settings
toggles) are not apps, so they stay in Settings. The store lists apps only, and never Home or
the App Store itself. `appStore.show --tab features` opens the store as it is, and `--category`
is ignored. The New Tab page's + opens Settings on the widget rows.

## Design

Data path: the page talks to the daemon (`cmux.apps.*`, unchanged) and to the host
(`cmux.app.*`, the native bridge). No new SwiftUI.

Icons: dynamic resource `glyph/<symbol>` (`AppsGlyphResource`) answers a PNG alpha mask of
**cmux's own icon pack** drawing for that symbol name (`IconCatalog.bundled.name(forSymbol:)`).
It never answers a system SF Symbol, so Q5 holds. The page draws the PNG with CSS `mask-image`
in `currentColor`, so the glyph follows the theme. An unknown name is a 404 and the page shows
initials.

Launching: `cmux.app.action.run` `app.open` (exists). Grants: the daemon's `grants.get` /
`grant.set` behind the host's native sheet (exists, `ConfirmingPageProvider`).

Routes: `#/discover`, `#/installed`, `#/discover?app=<id>`.
`AppsService.storeRoute(appID:tab:)` builds them; `AppStoreTab` (a small enum in
CmuxNextApps) parses `appStore.show --tab`.

Host: `AppsService.makeView` always returns the React `PageWebView`. If the page cannot load,
an empty view shows. Page history is the page's own. `PageTunables.appStore` is deleted, as
its doc says to do when the React page becomes the default.

## Deleted

`Store/AppStoreModel.swift`, `Store/AppStorePages.swift`, `Store/AppStoreContentView.swift`,
`Store/Views/*` (14 files), `AppStoreLayout` and `storeLayout` in `AppsTunables`, and the
store's `AppsRecovery` banner types plus `DaemonRecoveryControls.appsRecovery`.
`AppFeature`, its catalog and `SettingsAppFeatures` stay for now: the sidebar's item list
still reads them. Moving them to Settings is a500's follow-up.

## Not in this change

`Render/AppScene*`, `Section/AppSectionProvider`, `Section/AppSectionFrame` and
`Section/AppIconView` draw the app-defined scenes in sidebar sections and app pages. They stay
native, and a488 ports them to AppKit, not to web (a500, extensibility-DESIGN.md).

## Tests

- Web (bun): `icons.test.tsx`. A symbol icon draws as a `glyph/` mask, never as initials.
  Home and the App Store are never listed. An old `#/features` link opens Discover.
- Native (Swift Testing, CmuxNextAppTests): `AppsPageBridgeTests`. `glyph/` answers a PNG
  for a pack symbol and gives a 404 for an unknown or system-only name. The page admits no
  features op. `storeRoute` builds every route.
