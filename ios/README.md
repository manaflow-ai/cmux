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

## Pairing a sideloaded dev build with a real (beta/stable) Mac

A plain dev (DEBUG) build signs in to cmux's development Stack project. Stack
user ids are per-project, so a dev build's user id can never match the
production account binding (`ub`) a release Mac stamps into its pairing QR —
pairing fails instantly, even with the same email on the same tailnet
(https://github.com/manaflow-ai/cmux/issues/7145). To dogfood a device build
against your real Mac, build with production auth:

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
  your real Macs appear in Computers. The worker URLs live only in Swift —
  the script bakes no copy — and an explicit `CMUX_PRESENCE_BASE_URL` still
  wins.
- Skips the dogfood auto sign-in/auto-pair (those credentials belong to the
  development Stack project). Sign in in-app with the same account as your
  Mac.
- On first launch after switching auth environments on the same install, the
  app clears the previous environment's session/caches (tokens and user ids
  are per-Stack-project), so you start signed out instead of restoring a
  stale identity.

Scan the Mac's pairing QR with the **in-app** scanner. The system Camera app
routes release QR links (`cmux-ios://…`) to the beta/App Store app because
pairing URL schemes are channel-specific; the in-app scanner accepts both
schemes.

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
ship without re-review. The scheduled `main` sync lane now uploads
external-eligible builds too, so founders track `main` once the current version
has cleared that review gate. That lane reuses the checked-in
`ios/Config/Shared.xcconfig` `MARKETING_VERSION`; bump it only when you want a
fresh Beta App Review cycle. The upload path assigns the processed build to the
app's external beta group automatically, auto-selecting the single external
group or using `IOS_TESTFLIGHT_EXTERNAL_GROUP_ID` / `IOS_TESTFLIGHT_EXTERNAL_GROUP_NAME`
repo variables when the app has multiple external groups. When Apple reports the
build as `READY_FOR_BETA_SUBMISSION`, the same lane also creates the beta app
review submission automatically so a new `MARKETING_VERSION` is not left stuck
at "Ready to Submit".

If CI is moved back from a pending higher version to the last approved version,
external testers are unblocked because they could not install the pending build.
Internal testers who already installed that higher internal-only build will not
see lower-version builds as updates in TestFlight. They need a one-time app
reinstall, or operators need to cut an internal-only build on the higher version.

## TestFlight GitHub Actions signing

`.github/workflows/ios-testflight.yml` uses manual export signing because Xcode's
automatic App Store Connect export has produced IPAs whose signed app entitlements
omit `aps-environment=production`. That upload is intentionally blocked because
TestFlight push would silently fail. The workflow tracks `main` on a schedule and
uploads beta builds as external-eligible. Internal testers get the build
immediately, and the post-upload external distribution step both assigns the
build to the founders group and keeps using the checked-in approved
`MARKETING_VERSION`. When that version is intentionally bumped, the same
distribution step auto-submits the first build of the new version for Beta App
Review.

Required GitHub secrets:

- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_API_KEY_P8_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64` (base64-encoded `.p12` for an Apple Distribution certificate on team `7WLXT3NR37`)
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_BETA_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `dev.cmux.app.beta`, with `aps-environment=production`)

## App Store production lane

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
ios/scripts/validate-app-store-release.sh --app "$ASC_APP_ID" --version "$VERSION" --build-number "$CF_BUNDLE_VERSION" --wait-build --strict
```

Defaults:

- Bundle ID: `com.cmuxterm.app`
- Display name: `cmux`
- Provisioning profile: `cmux App Store Distribution`
- Entitlements: `Config/cmux-release.entitlements`

The review package lives in `ios/AppStoreReview/`:

- `review-notes.md` is the pasteable App Store Connect Review Information notes source.
- `metadata-screenshots-checklist.md` is the blocking checklist for metadata, screenshots, privacy, account deletion, and payment gating.

`.github/workflows/ios-app-store.yml` is manual-only. It uploads a production
build, waits for ASC processing, runs `ios/scripts/validate-app-store-release.sh`,
and submits for review only when `submit_for_review` is set.

Additional production workflow requirements:

- Repository variable `IOS_APPSTORE_APP_ID`
- Secret `IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `com.cmuxterm.app`, with `aps-environment=production`)
