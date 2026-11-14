# cmux iOS

SwiftUI iOS/iPadOS shell for the CMUXMobileCore production path.

Current phase:

- Stack Auth sign-in gate with Apple, Google, email code, and a debug-only `42` shortcut
- QR/manual pairing surface
- CMUXMobileCore pairing payload and attach-ticket decoding
- injectable `CmxByteTransportFactory` runtime hook
- isolated preview host data when no concrete transport is installed
- workspace list, workspace detail, terminal dropdown, and input bar

No Rust, Iroh, or Zig dependency is linked into this shell. Concrete route implementations should enter through `CMUXMobileRuntime`.

Build and reload the simulator:

```bash
ios/scripts/reload.sh --tag iossh
```

Run package tests:

```bash
swift test --package-path ios/cmuxPackage
```

## Build compatibility and production-auth DEV builds

A DEV iOS build connects only to the Mac DEV build with the same tag. BETA,
INTERNAL, and App Store iOS builds connect only to Stable or Nightly Mac builds.
Account environment does not change that compatibility boundary.

Use `--prod-auth` only when a tagged DEV build needs to test production account,
registry, or API behavior:

```bash
ios/scripts/reload.sh --tag my-tag --device-only --prod-auth
```

What `--prod-auth` does:

- Bakes `CMUXAuthEnvironment=production` into the app's Info.plist (via the
  `CMUX_IOS_AUTH_ENV` build setting), so the build signs in against the
  production Stack project and uses `https://cmux.com` for the device
  registry/API and the magic-link callback.
- Makes the presence worker follow the auth channel: the app resolves the
  production presence instance (see `PresenceClient.productionServiceURL`) so
  compatible Macs appear in Computers. The worker URLs live only in Swift;
  the script bakes no copy, and an explicit `CMUX_PRESENCE_BASE_URL` still
  wins.
- Skips the dogfood auto sign-in/auto-pair (those credentials belong to the
  development Stack project). Sign in in-app with the same account as your
  matching tagged DEV Mac.
- On first launch after switching auth environments on the same install, the
  app clears the previous environment's session/caches (tokens and user ids
  are per-Stack-project), so you start signed out instead of restoring a
  stale identity.

Every installed iOS bundle registers one URL scheme derived from its complete
bundle identifier, for example `cmux-ios-dev.cmux.app.beta://…` or
`cmux-ios-dev.cmux.ios.my-tag://…`. No two cmux builds register the same system
route. The authenticated Mac status supplies the exact instance tag, which the
app validates before it saves or adopts the connection.

Without the flag, the same override is available by bundling a
`LocalConfig.plist` with an `AuthEnvironment` string of `production` (see
`MobileAuthComposition`); a `LocalConfig.plist` entry wins over the baked
Info.plist value.

## TestFlight beta (cloud lane)

`ios/scripts/cloud-testflight.sh` is the turnkey lane for cutting a TestFlight
beta. It builds the heavy GhosttyKit + Swift Release compile on a leased fleet
Mac (same maclease pool as the device cloud reload, m1ultra excluded), so the
build stays off this Mac's CPU. The fleet produces an UNSIGNED Release archive
for the beta bundle id `dev.cmux.app.beta` (no signing material ever lands on
the shared Macs), downloads it locally, then hands it to
`ios/scripts/upload-testflight.sh --archive-path`, which does the local export,
re-sign with the Apple Distribution cert (re-adding `aps-environment=production`),
strict codesign verification, and TestFlight upload.

```bash
# Dry run: build + export + re-sign + verify aps-environment=production, NO upload
ios/scripts/cloud-testflight.sh --no-upload

# Full lane: build on the fleet and upload to TestFlight (internal "cmux beta" group)
ios/scripts/cloud-testflight.sh

# Also make the build eligible for external testers
ios/scripts/cloud-testflight.sh --external
```

A standalone cmux clone with no cmuxterm-hq checkout transparently falls back to
a LOCAL Release archive (`--local` forces it), then takes the same export path.

Internal testers (the `cmux beta` group) get every uploaded build instantly with
no review. An `--external` build is different: the FIRST external build of a new
`MARKETING_VERSION` must pass a one-time Apple Beta App Review (~24h) before any
external tester can install it. Subsequent external builds of the same version
ship without re-review. External cuts reuse
`CMUX_IOS_BETA_MARKETING_VERSION` from `ios/Config/Shared.xcconfig`; bump it
only when you want a fresh Beta App Review cycle. The upload path assigns the
processed build to both the Founder's Edition and Pro external beta groups. It
uses `CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID` /
`CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME` for the primary group and
`CMUX_TESTFLIGHT_PRO_GROUP_ID` for Pro. GitHub Actions maps the repository
variables `IOS_TESTFLIGHT_EXTERNAL_GROUP_ID`,
`IOS_TESTFLIGHT_EXTERNAL_GROUP_NAME`, and `IOS_TESTFLIGHT_PRO_GROUP_ID` to those
script inputs. When Apple reports the build as `READY_FOR_BETA_SUBMISSION`, the
same lane also creates the beta app review submission automatically so a new
`MARKETING_VERSION` is not left stuck at "Ready to Submit".

If CI is moved back from a pending higher version to the last approved version,
external testers are unblocked because they could not install the pending build.
Internal testers who already installed that higher internal-only build will not
see lower-version builds as updates in TestFlight. They need a one-time app
reinstall, or operators need to cut an internal-only build on the higher version.

## TestFlight GitHub Actions signing

`.github/workflows/ios-testflight.yml` uses manual export signing because Xcode's
automatic App Store Connect export has produced IPAs whose signed app
entitlements omit `aps-environment=production`. That upload is intentionally
blocked because TestFlight push would silently fail. Scheduled `main` uploads
ship only to the internal TestFlight group. A manual run with
`marketing_version_override` switches to the external beta bundle, installs its
provisioning profile, and assigns the processed build to both the Founder's
Edition and Pro groups. That external override reuses an already approved
marketing version and auto-submits the first build when Apple reports that Beta
App Review is required.

Required GitHub secrets:

- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_API_KEY_P8_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64` (base64-encoded `.p12` for an Apple Distribution certificate on team `7WLXT3NR37`)
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_BETA_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `dev.cmux.app.beta`, with `aps-environment=production`)

## cmux CLASSIC TestFlight lane

The App Store record `com.cmux.app` (App Store Connect app 6783338052) now
ships cmux-next from `feat-cmux-next`. This classic app no longer goes to the
App Store. Its internal TestFlight-only home is the App Store Connect app
**cmux CLASSIC**, bundle ID `dev.cmux.app.classic`.

```bash
# Build, export, re-sign, verify, and upload to cmux CLASSIC
ASC_APP_ID=<cmux CLASSIC app id> ios/scripts/upload-testflight.sh --lane classic

# Dry run: export + re-sign + verify, no upload
ios/scripts/upload-testflight.sh --lane classic --export-only
```

Defaults:

- Bundle ID: `dev.cmux.app.classic`; notification extension `dev.cmux.app.classic.NotificationService`
- Keychain access group: `7WLXT3NR37.dev.cmux.app.classic`
- Marketing version: `CMUX_IOS_CLASSIC_MARKETING_VERSION` in `ios/Config/Shared.xcconfig` (1.0.x)
- Display name: `cmux CLASSIC`
- Build: the VPN-free App Store binary (`Config/cmux-appstore-release.entitlements`), internal TestFlight only
- The lane refuses `com.cmux.app` and App Store Connect app 6783338052.

`.github/workflows/ios-appstore-upload.yml` polls `main` hourly and uploads
batched revisions to cmux CLASSIC, then assigns each build to its internal
group. It stays a no-op until these repository variables are set:

- `IOS_CLASSIC_ASC_APP_ID`: the numeric App Store Connect app id of cmux CLASSIC
- `IOS_CLASSIC_INTERNAL_GROUP_ID`: the id of its internal TestFlight group

The provisioning profiles for the app and its notification extension are found
or created through the App Store Connect API with the CI distribution
certificate. The optional secrets `IOS_CLASSIC_PROVISIONING_PROFILE_BASE64` and
`IOS_CLASSIC_EXTENSION_PROVISIONING_PROFILE_BASE64` pin specific profiles instead.

## App Store production lane (retired for the classic app)

`ios/scripts/upload-app-store.sh` and `.github/workflows/ios-app-store.yml`
refuse to upload or submit this classic app: `com.cmux.app` ships cmux-next,
and the cmux-next App Store lane on `feat-cmux-next` replaces this one.
`upload-app-store.sh --export-only` still works for a local dry run. The rest
of this section describes the retired lane.

The production App Store lane is separate from the TestFlight beta lane. It uses
the same archive/export/re-sign verification path, but switches the submitted
identity to the App Store bundle id and stops before App Review submission unless
the operator explicitly confirms submission in CI.

```bash
# Build, export, re-sign, verify, and upload the production App Store build
ios/scripts/upload-app-store.sh

# Dry run: export + re-sign + verify aps-environment=production, no upload
ios/scripts/upload-app-store.sh --export-only

# Run the read-only ASC readiness package after upload
ios/scripts/validate-app-store-release.sh --app "$ASC_APP_ID" --build-number "$CF_BUNDLE_VERSION" --wait-build --strict
```

Defaults:

- Bundle ID: `com.cmux.app`
- Marketing version: `CMUX_IOS_APPSTORE_MARKETING_VERSION` in `ios/Config/Shared.xcconfig`
- Display name: `cmux`
- Provisioning profile: `cmux App Store Distribution`
- Entitlements: `Config/cmux-appstore-release.entitlements` (VPN-free App Store build; beta keeps `Config/cmux-release.entitlements`)

The review package lives in `ios/AppStoreReview/`:

- `review-notes.md` is the pasteable App Store Connect Review Information notes source.
- `metadata-screenshots-checklist.md` is the blocking checklist for metadata, screenshots, privacy, account deletion, and payment gating.

`.github/workflows/ios-app-store.yml` is manual-only, and every dispatch now
fails in its `refuse-classic` job. It used to upload a production build, wait
for ASC processing, run `ios/scripts/validate-app-store-release.sh`, and submit
for review only when `submit_for_review` was set.

Additional production workflow requirements:

- Repository variable `IOS_APPSTORE_APP_ID`
- Secret `IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `com.cmux.app`, with `aps-environment=production`)
