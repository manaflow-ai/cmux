# cmux iOS App Review Access Setup

Use this source to prepare the App Store Connect Review Information for the
official cmux iOS app, Apple ID `6783338052`. Do not commit passwords, one-time
codes, or live access secrets.

## Required Review Environment

The reviewer must be able to test cmux for iOS without owning a Mac or installing
another networking app. Keep a prepared review Mac online and signed in to the
same demo account and team entered in App Store Connect.

The prepared Mac must:

- Run the production cmux macOS app compatible with the submitted iOS build.
- Run against the deployed production backend that supports account-discovered
  live-session handoff.
- Keep Mobile Pairing enabled and show Iroh as ready before submission.
- Stay awake and reachable from Apple review networks.
- Use a dedicated review-only macOS user on a dedicated review Mac or VM. Do not
  sign in with personal Apple IDs, GitHub accounts, production developer
  credentials, password managers, SSH keys, cloud drives, Messages, or other
  private services.
- Use fictional account, workspace, terminal, file, and device names.
- Keep a safe workspace and live session named `App Review` available for
  harmless commands such as `echo app-review-ok`, `pwd`, and `date`.
- Continue publishing the review Mac's encrypted Iroh route and bounded live
  session summary to the authenticated device registry throughout review.

Do not put a generated pairing link in App Store Connect as the primary review
path. Attach links are short-lived and may expire while the submission waits in
Apple's queue. Account-discovered handoff is the durable review path. A fresh QR
can be used only as live support if Apple contacts the monitored review owner.

After review, revoke the demo access, reset the review macOS user, and delete any
files created during review.

## App Store Connect Review Information

Fill the App Store Connect fields for Apple ID `6783338052`:

- Demo account email: enter only in App Store Connect.
- Demo account password or stable access instructions: enter only in App Store
  Connect.
- Contact name, email, and phone: use a monitored owner.
- Notes: paste the block below, then replace the contact placeholders with live
  submission-specific details.

Pasteable notes block:

```text
cmux for iOS is a companion app for the cmux macOS terminal. The reviewer does
not need to own a Mac or install a VPN or third-party networking app. We keep a
prepared review Mac online and signed in to this demo account.

Demo account:
- Use the credentials in the App Review demo account fields.

Connection:
1. Launch cmux.
2. Sign in with the demo account.
3. Complete the short onboarding flow.
4. On the first connection screen, find Continue on This Device.
5. Tap the App Review session. cmux connects through its built-in encrypted
   device connection and opens the workspace.

Expected result:
- The App Review workspace opens from the prepared review Mac.
- The terminal is ready for harmless commands.
- Type: echo app-review-ok
- The terminal should print: app-review-ok

Optional permissions:
- Local Network improves direct connectivity when both devices share a network;
  remote review access does not require joining the Mac's network.
- Camera is used only to scan pairing QR codes.
- Microphone and Speech Recognition are used only for voice transcription.
- Photos are used only when attaching selected photos to a terminal-agent message.
- Notifications are optional and can be enabled or disabled from the app.

Payments:
- This App Store build has no purchase, upgrade, checkout, or billing-management
  links. Existing paid access from web or desktop accounts is read-only.

Support during review:
- Contact <REVIEW_CONTACT_EMAIL> or <REVIEW_CONTACT_PHONE> if the prepared Mac or
  App Review session is unavailable.
```

## Pre-Submission Check

Before submitting:

1. Deploy the production web API that publishes and returns owner-only live
   session summaries.
2. Install the final signed App Store IPA as a clean installation on an iPhone or
   iPad that has never paired with the review Mac.
3. Disable VPN software and test from a network outside the office and outside
   the prepared Mac's LAN.
4. Sign in with the exact App Review demo account and complete onboarding.
5. Confirm the pairing sheet does not cover the first connection screen when the
   `App Review` session is available.
6. Tap `App Review`, send `echo app-review-ok`, and confirm the output.
7. Leave the prepared Mac awake, Mobile Pairing enabled, Iroh ready, and the
   `App Review` session active until Apple completes review.
8. Confirm the Privacy Policy URL in App Store Connect is
   `https://cmux.com/privacy-policy`.
9. Replace every angle-bracket contact placeholder in the notes with a monitored
   live value. Demo credentials and contacts must never be committed here.
