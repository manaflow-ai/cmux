# iOS App Privacy Matrix

Last updated: July 8, 2026.

Sources:
- Apple App Privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Apple Manage app privacy help: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
- Apple privacy manifests: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Apple required reason APIs: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

## App Store Connect Links

Privacy Policy URL: `https://cmux.com/privacy-policy`

Privacy Choices URL: `https://cmux.com/privacy-policy`

Reason: iOS users can opt out of product analytics in `Settings > Privacy > Share Product Analytics`; the policy explains account deletion, access, deletion, and contact paths.

## Tracking

Does cmux track users across apps or websites owned by other companies?

Answer: No.

Details:
- No IDFA access.
- No App Tracking Transparency prompt.
- No third-party advertising or data broker sharing.
- `PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` to `false` and declares no tracking domains.

## Data Collection Answers

| App Store data type | Collected | Linked to user | Used for tracking | Purposes | Notes |
| --- | --- | --- | --- | --- | --- |
| Contact Info, Name | Yes | Yes | No | App Functionality | Account display name from sign-in, when present. |
| Contact Info, Email Address | Yes | Yes | No | App Functionality | Account sign-in, account matching, feedback reply-to. |
| Identifiers, User ID | Yes | Yes | No | App Functionality, Analytics | Stack user id for account pairing and analytics identity after sign-in. |
| Identifiers, Device ID | Yes | Yes | No | App Functionality, Analytics | App-generated install and device identifiers for pairing, device registry, multi-device sync, and analytics grouping. |
| Usage Data, Product Interaction | Yes | Yes | No | Analytics | Product events such as launch, foreground/background, session, sign-in result, pairing result, workspace open, push opt-in, and terminal input byte counts. Terminal text is not collected for analytics. |
| User Content, Other User Content | Yes | Yes | No | App Functionality | User-submitted feedback message. Terminal content, pasted content, images, and files are sent to the user's paired Mac, not collected by Manaflow, unless the user explicitly submits feedback. |
| Diagnostics, Other Diagnostic Data | Yes | Yes | No | App Functionality | Feedback build stamp, OS version, hardware model, and diagnostic bundle only when the user submits feedback. |

## Data Types Not Selected

Do not select these for the current iOS build:
- Location: no precise or coarse location collection.
- Contacts: no address book access.
- Browsing History: no browsing history collection by the iOS app.
- Search History: no search query collection.
- Purchase History, Financial Info, Health and Fitness, Sensitive Info: not collected.
- Photos or Videos: attachments are user-selected and sent to the user's paired Mac terminal, not retained by Manaflow.
- Audio Data: microphone and speech recognition support dictation into the message box; audio is not collected by Manaflow.
- Crash Data: the iOS app does not currently send crash reports to Sentry. If crash reporting is enabled later, update this matrix and `PrivacyInfo.xcprivacy`.

## Required Reason APIs

Declared in `ios/cmux/Resources/PrivacyInfo.xcprivacy`.

| API category | Reason | Why cmux uses it |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Persist app-only settings and state: auth cache, pairing state, analytics opt-out, client id, onboarding, display preferences, session state, push state. |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Inspect app-local file metadata and file sizes for local config loading, debug build stamps, and preflight checks before user-selected attachments are processed. |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | Measure elapsed time inside the app for terminal rendering, cursor timing, input idle checks, animation timing, and in-app duration metrics. |

## Privacy Manifest Coverage

`ios/cmux/Resources/PrivacyInfo.xcprivacy` declares:
- `NSPrivacyTracking = false`
- no tracking domains
- the collected data types listed above
- the required reason API categories listed above

Keep this file, the App Store Connect answers, and `web/app/[locale]/(legal)/privacy-policy/page.tsx` in sync whenever iOS data collection changes.
