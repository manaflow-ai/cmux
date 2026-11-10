# cmux iOS Review Notes

This file is reference-only background for the team. The single canonical App
Store Connect notes template is the pasteable notes block in
`reviewer-setup.md`; do not paste this file into App Store Connect.

cmux for iOS is a companion app for the cmux macOS terminal. It lets a signed-in
user pair with their Mac, view workspaces, receive terminal notifications, and
send input to an active terminal session from iPhone or iPad.

Official App Store Connect app: Apple ID `6783338052`.

Demonstration mode: the review demo account is server-flagged
(`cmuxReviewDemoContent: true` in Stack `clientReadOnlyMetadata`, set with
`web/scripts/set-review-demo-content.ts`). After sign-in the app shows a local
"Demo Mac" with sample developer workspaces, notifications, and interactive
canned terminals through the same UI as a live Mac, so the reviewer can
exercise the full app even if the prepared review Mac or its network route is
temporarily unreachable. Real computers still appear alongside it.

Reviewer access:

- Use the demo account entered in App Store Connect Review Information. Do not
  put demo credentials in this repository.
- For a Mailinator demo account, put the exact demo email in the ASC demo
  account field and put the public inbox URL in ASC notes. State that the app
  sends a one-time email code and that no Mailinator account is required.
- The reviewer does not need a Mac, a VPN or any network setup. The flagged
  review account goes from onboarding straight to its Demo Mac; the
  connection-method picker is hidden for it, so the notes give no manual
  pairing fallback.
- The app may request Local Network permission during pairing so it can discover
  and connect to the user's Mac.
- Camera permission is used only to scan cmux pairing QR codes.
- Microphone and speech recognition permissions are used only when the reviewer
  chooses voice transcription in the message box.
- Photo library permission is used only when the reviewer attaches a photo to a
  terminal-agent message.

Payments:

- The iOS app sells the cmux Pro and Max monthly subscriptions (Go stays
  behind its rollout flag, see `subscriptions.json`) through
  StoreKit in-app purchase only (subscription group "cmux Plans"). Open
  Settings > Account > Plan, or Cloud > Upgrade, to see the plans screen with
  Restore Purchases, Manage Subscription, the auto-renewal terms, and links to
  the Terms of Service and Privacy Policy.
- The app does not expose Stripe, Stack checkout, external purchase links, or
  billing management links. Accounts that already pay on the web see a
  plain-text note and no purchase buttons.
- The web billing surface is gated for App Store mode with
  `cmux_distribution=appstore`; direct checkout requests with that distribution
  are redirected before Stack or Stripe checkout creation.
- Direct billing portal requests with `cmux_distribution=appstore` are also
  redirected before Stack or Stripe portal session creation.
- Use a Sandbox Apple Account to test a purchase. The server verifies each
  signed transaction and grants the plan to the signed-in cmux account.

Privacy and account handling:

- Sign in supports Apple, Google, GitHub, and email code through Stack Auth.
- Push notifications are opt-in. The device token is uploaded only after the user
  enables phone notifications.
- `ITSAppUsesNonExemptEncryption` is `false`; the app uses standard platform
  networking and TLS.

Primary review path (the App Store Connect notes are rendered from
`review-notes-asc.txt` on every `ios-app-store.yml` run):

1. Sign in with the demo account supplied in App Store Connect.
2. For email-code sign-in, open the Mailinator public inbox URL supplied in the
   notes and enter the newest one-time code from the email subject.
3. Onboarding shows "Your Mac is connected"; tap Open Workspaces.
4. Open any workspace on "Demo Mac".
5. Send `echo app-review-ok` from the message box.
6. Enable phone notifications and verify the opt-in prompt, then disable them
   again from the same surface.
