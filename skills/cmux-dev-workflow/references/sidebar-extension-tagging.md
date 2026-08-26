# Sidebar Extension Tagging

The three build settings and why display name matters are in [../SKILL.md](../SKILL.md).

## What reload-extension.sh passes

`./scripts/reload-extension.sh --tag <tag> [--host-bundle-id <id>] [--example sample|tabs|both]` builds a tag-scoped sample extension with:

- `CMUX_SIDEBAR_EXTENSION_POINT_ID=<host-bundle-id>.cmux.sidebar`
- `CMUX_BUNDLE_ID_SUFFIX=.<tag>`
- `CMUX_DISPLAY_NAME_SUFFIX=" <tag>"`

It installs exactly what xcodebuild produced and does **not** re-sign. A bare `codesign --force --sign -` strips the appex entitlements and the extension then drops its host XPC connection. pkd ingests the tagged copy because its bundle id is distinct.

Verify with:

```bash
pluginkit -m -p <host-bundle-id>.cmux.sidebar
```

## New tag-ready sample extension checklist

- appex Info.plist: `EXAppExtensionAttributes:EXExtensionPointIdentifier = $(CMUX_SIDEBAR_EXTENSION_POINT_ID)`.
- app and appex targets define `CMUX_SIDEBAR_EXTENSION_POINT_ID` (default `com.cmuxterm.app.cmux.sidebar`), `CMUX_BUNDLE_ID_SUFFIX` (default empty), and `CMUX_DISPLAY_NAME_SUFFIX` (default empty) in all build configs.
- app `PRODUCT_BUNDLE_IDENTIFIER` = `<appBase>$(CMUX_BUNDLE_ID_SUFFIX)`; appex = `<appBase>$(CMUX_BUNDLE_ID_SUFFIX).<leaf>`, so the suffix lands before the appex leaf and the appex id stays prefixed by the app id.
- appex `INFOPLIST_KEY_CFBundleDisplayName` (or the `CFBundleDisplayName` value) = `<Name>$(CMUX_DISPLAY_NAME_SUFFIX)`.
- xcodebuild ad-hoc signs the appex with Info.plist bound and entitlements intact; do not re-sign post-build.
