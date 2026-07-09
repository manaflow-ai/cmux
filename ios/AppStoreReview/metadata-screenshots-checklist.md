# cmux iOS Metadata and Screenshots Checklist

Do not submit a production iOS App Store build until every blocking item is
complete in App Store Connect or in the submitted binary.

## App Identity

- [ ] Bundle ID is `com.cmuxterm.app`.
- [ ] Display name is `cmux`, not `cmux BETA` or any dev tag.
- [ ] `MARKETING_VERSION` in `ios/Config/Shared.xcconfig` matches the App Store version.
- [ ] `CURRENT_PROJECT_VERSION` is higher than every prior ASC build for the app.
- [ ] `ITSAppUsesNonExemptEncryption` remains `false` only if the build uses no non-exempt encryption beyond standard TLS.

## Review Information

- [ ] App Review contact name, email, and phone are filled in ASC.
- [ ] Demo account credentials are entered only in ASC Review Information, never in git.
- [ ] `review-notes.md` is pasted into ASC notes and edited with the exact review Mac or manual pairing code for this build.
- [ ] Backend services needed by the demo account are live before submission.
- [ ] Account deletion is available in app or the submission is blocked until the account lifecycle satisfies App Review Guideline 5.1.1(v).

## Metadata

- [ ] App name is 30 characters or fewer and does not include pricing text.
- [ ] Subtitle, description, keywords, support URL, marketing URL, and privacy policy URL are complete for every ASC localization.
- [ ] Description accurately says cmux is an iOS companion for the cmux macOS terminal.
- [ ] Metadata does not describe TestFlight, beta access, dev builds, unfinished features, or unsupported platforms.
- [ ] Category and age rating are complete and match the app's terminal, remote-control, notifications, and account features.
- [ ] Content rights declaration is complete.
- [ ] App Privacy answers match collected data: account identifiers, device token when push is enabled, analytics if enabled, and pairing/device metadata.

## Screenshots

- [ ] Screenshots show the actual app in use, not only splash, login, title art, or marketing copy.
- [ ] Include signed-in workspace list, pairing/computers, terminal detail, input bar, and notification opt-in surfaces.
- [ ] Use fictional workspace names, terminal text, email addresses, device names, and account data.
- [ ] Include required iPhone screenshots, at minimum `IPHONE_65`.
- [ ] Include required iPad screenshots if the binary remains universal (`TARGETED_DEVICE_FAMILY = 1,2`), at minimum `IPAD_PRO_3GEN_129`.
- [ ] Local screenshot assets pass `asc screenshots validate` before upload.

## Payments

- [ ] The iOS App Store build exposes no Stripe, Stack checkout, external purchase, external upgrade, or billing-management link.
- [ ] `/app-pricing?cmux_app=1&cmux_distribution=appstore` renders without `/api/billing/checkout`, `/api/billing/portal`, or enterprise sales CTAs.
- [ ] `/api/billing/checkout?cmux_distribution=appstore` redirects before creating Stack or Stripe checkout state.
- [ ] Existing paid entitlement state is read-only in iOS. If an iOS purchase flow is added later, it must use StoreKit and restore purchases.

## Permissions and Privacy

- [ ] Camera purpose string says QR pairing scan.
- [ ] Local Network purpose string says Mac pairing and terminal sync.
- [ ] Microphone and speech recognition purpose strings say voice transcription in the message box.
- [ ] Photo library purpose string says attaching photos to terminal-agent messages.
- [ ] Permissions are requested only when the user starts the relevant feature.
- [ ] Push notifications are opt-in and can be disabled after enabling.

## ASC Validation Commands

```bash
ios/scripts/validate-app-store-release.sh \
  --app "$ASC_APP_ID" \
  --version "$VERSION" \
  --build-number "$CF_BUNDLE_VERSION" \
  --wait-build \
  --strict
```

```bash
asc validate --app "$ASC_APP_ID" --version "$VERSION" --platform IOS --strict --output table
```

```bash
asc metadata validate --dir ios/AppStoreReview/metadata --output table
```

```bash
asc screenshots validate --path ios/AppStoreReview/screenshots --device-type IPHONE_65 --output table
asc screenshots validate --path ios/AppStoreReview/screenshots --device-type IPAD_PRO_3GEN_129 --output table
```
