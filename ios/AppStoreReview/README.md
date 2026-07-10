# cmux iOS App Store Review Package

This package is the source of truth for production iOS App Store submission
readiness. Keep it separate from the TestFlight beta lane.

## Production Lane

Upload a production App Store Connect build:

```bash
ios/scripts/upload-app-store.sh
```

Useful dry run:

```bash
ios/scripts/upload-app-store.sh --export-only
```

Defaults:

- Bundle ID: `com.cmuxterm.app`
- Display name: `cmux`
- Provisioning profile: `cmux App Store Distribution`
- Entitlements: `Config/cmux-release.entitlements`
- Review submission: not automatic

The beta lane remains:

```bash
ios/scripts/upload-testflight.sh --lane beta
```

## Validation

Run the App Store readiness package after upload:

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --version "$(sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' ios/Config/Shared.xcconfig | head -1)" \
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

- `review-notes.md` contains the notes to paste into App Store Connect Review Information.
- `metadata-screenshots-checklist.md` lists the metadata, screenshots, privacy, and payment gates that must be complete before submission.

Do not commit demo account passwords. Add them only in App Store Connect Review
Information fields.
