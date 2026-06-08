# Sidebar extension point (dev tagging)

How tagged dev builds get isolated ExtensionKit sidebar extension points so concurrent dev builds don't collide. Summarized in `CLAUDE.md`; full mechanics here.

Each tagged dev build gets its own ExtensionKit sidebar extension point so concurrent dev builds don't collide. Three build settings drive this:

- `CMUX_SIDEBAR_EXTENSION_POINT_ID` (default `com.cmuxterm.app.cmux.sidebar`): the extension point identifier baked into Info.plist at build time.
- `CMUX_BUNDLE_ID_SUFFIX` (default empty): inserted into the app and appex bundle ids so a tagged extension gets a distinct identity that pkd records separately.
- `CMUX_DISPLAY_NAME_SUFFIX` (default empty): appended to the appex `CFBundleDisplayName`. The OS groups sidebar extensions by display name for the enable/disable + availability counts the host reads (`AppExtensionIdentity` exposes only `bundleIdentifier`, `localizedName`, `extensionPointIdentifier`, `id` — cmux already keys its own identity off the stable `bundleIdentifier`, but the OS-level grouping is by name). Two same-named appexes installed side by side (a base build and a tagged build) are treated as one logical extension, so toggling one perturbs the other; a per-tag display name keeps them distinct.

The host resolves its point id at runtime from the Info.plist key `CMUXSidebarExtensionPointIdentifier` via `CmuxSidebarExtensionPoint.identifier(in:)`. `./scripts/reload.sh --tag <tag>` scopes the host point to `com.cmuxterm.app.debug.<tag>.cmux.sidebar`. `./scripts/reload-extension.sh --tag <tag> [--host-bundle-id <id>] [--example sample|tabs|both]` builds a matching tag-scoped sample extension, passing `CMUX_SIDEBAR_EXTENSION_POINT_ID=<host-bundle-id>.cmux.sidebar`, `CMUX_BUNDLE_ID_SUFFIX=.<tag>`, and `CMUX_DISPLAY_NAME_SUFFIX=" <tag>"`. It installs exactly what xcodebuild produced (xcodebuild ad-hoc signs with entitlements intact) — it does NOT re-sign, because a bare `codesign --force --sign -` strips the appex entitlements and the extension then drops its host XPC connection. pkd ingests the tagged copy because its bundle id is distinct. Verify with `pluginkit -m -p <host-bundle-id>.cmux.sidebar`.

To author a NEW sample extension that is tag-ready:
- appex Info.plist: `EXAppExtensionAttributes:EXExtensionPointIdentifier = $(CMUX_SIDEBAR_EXTENSION_POINT_ID)`.
- add `CMUX_SIDEBAR_EXTENSION_POINT_ID` (default `com.cmuxterm.app.cmux.sidebar`), `CMUX_BUNDLE_ID_SUFFIX` (default empty), and `CMUX_DISPLAY_NAME_SUFFIX` (default empty) build settings to the app and appex targets in all build configs.
- `PRODUCT_BUNDLE_IDENTIFIER` = `<appBase>$(CMUX_BUNDLE_ID_SUFFIX)` for the app target and `<appBase>$(CMUX_BUNDLE_ID_SUFFIX).<leaf>` for the appex (suffix before the appex leaf so the appex id stays prefixed by the app id).
- appex `INFOPLIST_KEY_CFBundleDisplayName` (or the `CFBundleDisplayName` Info.plist value) = `<Name>$(CMUX_DISPLAY_NAME_SUFFIX)`.
- it must be ad-hoc signed by xcodebuild (Info.plist bound, entitlements intact) for pkd to ingest the tagged copy; do not re-sign post-build.
