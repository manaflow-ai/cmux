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
has cleared that review gate.

## TestFlight GitHub Actions signing

`.github/workflows/ios-testflight.yml` uses manual export signing because Xcode's
automatic App Store Connect export has produced IPAs whose signed app entitlements
omit `aps-environment=production`. That upload is intentionally blocked because
TestFlight push would silently fail. The workflow tracks `main` on a schedule and
uploads beta builds as external-eligible, so internal testers get the build
immediately and external testers get the same `main` build once Apple has
approved that `MARKETING_VERSION` for Beta App Review.

Required GitHub secrets:

- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_API_KEY_P8_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64` (base64-encoded `.p12` for an Apple Distribution certificate on team `7WLXT3NR37`)
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_BETA_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `dev.cmux.app.beta`, with `aps-environment=production`)
