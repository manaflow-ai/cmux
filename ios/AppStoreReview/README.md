# cmux iOS App Store Review Package

This package is the source of truth for production iOS App Store submission
readiness. Keep it separate from the TestFlight beta lane.

## Production Lane

The official cmux iOS App Store Connect app is Apple ID `6783338052`.

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

The beta lane remains:

```bash
ios/scripts/upload-testflight.sh --lane beta
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

## App Review Journey

`journey-tests.txt` lists the UI tests that walk the path App Review takes
through a fresh install with no Mac of its own: the signed-out first screen,
Tailscale scan and Skip without a Mac, and the demonstration account.
`test-ios.yml` runs them on iPhone and iPad in every iOS pull request and
merge-group run, inside the `ios-tests` gate, so a build that would strand a
reviewer goes red in its pull request, long before App Store Connect sees it.

When App Review rejects the app for its behaviour (Guideline 2.1 and the like),
the fix PR adds the test that would have caught it to the list, failing on the
base, before the fix. A test that needs an App Review state the app cannot
reach on its own (the demonstration account, no Tailscale) gets a
`CMUX_UITEST_*` stand-in, as `CMUX_UITEST_ONBOARDING_DEMONSTRATION_ACCOUNT`
does. `ios/tests/test_appstore_review_package.py` fails if the list, a test it
names or the CI step goes away.

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
