# cmux iOS App Store Review Package

This package is the source of truth for production iOS App Store submission
readiness. Keep it separate from the TestFlight beta lane.

## Production Lane

The official cmux iOS App Store Connect app is Apple ID `6783338052`. It now
ships cmux-next from `feat-cmux-next`, so this classic app is no longer
uploaded or submitted from `main`: `upload-app-store.sh` refuses to upload and
`.github/workflows/ios-app-store.yml` fails every dispatch. The classic app's
internal TestFlight home is cmux CLASSIC (`dev.cmux.app.classic`, see
`ios/README.md`). The steps below describe the retired lane.

Upload a production App Store Connect build:

```bash
ios/scripts/upload-app-store.sh
```

Useful dry run:

```bash
ios/scripts/upload-app-store.sh --export-only
```

Defaults:

- Bundle ID: `com.cmux.app`
- Marketing version: `CMUX_IOS_APPSTORE_MARKETING_VERSION` in `ios/Config/Shared.xcconfig`
- Display name: `cmux`
- Provisioning profile: `cmux App Store Distribution`
- Entitlements: `Config/cmux-appstore-release.entitlements` (VPN-free App Store build; beta keeps `Config/cmux-release.entitlements`)
- Review submission: not automatic

The beta and cmux CLASSIC lanes remain:

```bash
ios/scripts/upload-testflight.sh --lane beta
ios/scripts/upload-testflight.sh --lane classic
```

## Validation

Run the App Store readiness package after upload:

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --build-number "$CF_BUNDLE_VERSION" \
  --wait-build \
  --strict
```

Preview staging with copied metadata:

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --version "$VERSION" \
  --build-number "$CF_BUNDLE_VERSION" \
  --copy-metadata-from "$PREVIOUS_VERSION" \
  --stage-dry-run \
  --strict
```

Preview review submission:

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --version "$VERSION" \
  --build-number "$CF_BUNDLE_VERSION" \
  --submit-dry-run \
  --strict
```

Only submit after the checklist is complete:

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --version "$VERSION" \
  --build-number "$CF_BUNDLE_VERSION" \
  --submit \
  --confirm-submit \
  --strict
```

## Files

- `reviewer-setup.md` contains the prepared Mac, automatic review-Mac route, and
  manual fallback setup needed so App Review can test without owning a Mac. Its
  pasteable notes block is the single canonical App Store Connect notes
  template.
- `review-notes.md` is reference-only background on the review flow and
  permissions. Do not paste it into App Store Connect.
- `metadata-screenshots-checklist.md` lists the metadata, screenshots, privacy, and payment gates that must be complete before submission.

Do not commit demo account passwords. Add them only in App Store Connect Review
Information fields.
