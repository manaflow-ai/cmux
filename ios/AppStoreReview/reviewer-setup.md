# cmux iOS App Review Access Setup

Use this source to prepare the App Store Connect Review Information for the
official cmux iOS app, Apple ID `6783338052`. Do not commit passwords, one-time
codes, or live pairing secrets.

## Required Review Environment

The reviewer must be able to test cmux for iOS without owning a Mac. Before
submission, keep a prepared review Mac online and signed in to the same demo
account entered in App Store Connect.

The prepared Mac must:

- Run the production cmux macOS app that matches the submitted iOS backend.
- Stay awake, unlocked after reboot, and reachable from Apple review networks.
- Use fictional account, workspace, terminal, file, and device names.
- Expose a safe workspace named `App Review`.
- Keep a terminal ready for harmless commands such as `echo app-review-ok`,
  `pwd`, and `date`.
- Have any required pairing route, relay, or tunnel live before submission.

Do not rely on LAN-only discovery for review. If the pairing code resolves only
to a private local-network address, the reviewer will not be able to verify the
app from Apple.

## App Store Connect Review Information

Fill the App Store Connect fields for Apple ID `6783338052`:

- Demo account email: enter only in App Store Connect.
- Demo account password or stable access instructions: enter only in App Store
  Connect.
- Contact name, email, and phone: use a monitored owner.
- Notes: paste `review-notes.md`, then replace the placeholders below with live
  submission-specific details.

Pasteable notes block:

```text
cmux for iOS is a companion app for the cmux macOS terminal. The reviewer does
not need to own or install cmux on a Mac. We have prepared a review Mac that is
already online and signed in to this demo account.

Demo account:
- Use the credentials in the App Review demo account fields.

Pairing:
1. Launch cmux.
2. Sign in with the demo account.
3. Tap Add Computer.
4. Choose manual pairing.
5. Enter this pairing code: <LIVE_PAIRING_CODE_FOR_THIS_BUILD>

Expected result:
- A computer named "App Review Mac" appears.
- Open the "App Review" workspace.
- The terminal is ready for harmless commands.
- Type: echo app-review-ok
- The terminal should print: app-review-ok

Optional permissions:
- Local Network is used for Mac pairing and terminal sync.
- Camera is used only to scan pairing QR codes.
- Microphone and Speech Recognition are used only for voice transcription.
- Photos are used only when attaching selected photos to a terminal-agent message.
- Notifications are optional and can be enabled or disabled from the app.

Payments:
- This App Store build has no purchase, upgrade, checkout, or billing-management
  links. Existing paid access from web or desktop accounts is read-only.

Support during review:
- Contact <REVIEW_CONTACT_EMAIL> or <REVIEW_CONTACT_PHONE> if the prepared Mac
  or pairing code is unreachable.
```

## Pre-Submission Check

Before submitting:

1. Sign in to the iOS App Store build with the review account.
2. Pair using the exact code that will be pasted into App Store Connect.
3. Open the `App Review` workspace.
4. Send `echo app-review-ok`.
5. Confirm the prepared Mac remains reachable from a network outside the office
   LAN.
6. Confirm the Privacy Policy URL in App Store Connect is
   `https://cmux.com/privacy-policy`.
