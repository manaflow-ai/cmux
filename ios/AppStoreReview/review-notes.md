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
- The reviewer does not need to own or install cmux on a Mac. Before submission,
  keep the prepared review Mac online, signed in to the same demo account, and
  visible to the iOS app through the production device registry or relay path.
  If automatic discovery is verified, the ASC notes should say that the review
  Mac appears automatically after sign-in and that no VPN or network
  configuration is required.
- Keep a manual fallback ready in ASC notes if automatic discovery fails:
  - Name: `App Review Mac`
  - Host: `<TAILSCALE_MAGICDNS_OR_100_X_ADDRESS>`
  - Port: `<CMUX_MOBILE_HOST_PORT>`
  - Tailscale access: `<TAILSCALE_REVIEW_ACCESS>`
  - Review contact: `<REVIEW_CONTACT_EMAIL>` / `<REVIEW_CONTACT_PHONE>`
- The prepared Mac must use a dedicated review-only macOS user, no personal or
  developer credentials, a safe `App Review` workspace, and a route restricted
  to review access. Revoke the credentials and reset the review user after App
  Review finishes.
- The app may request Local Network permission during pairing so it can discover
  and connect to the user's Mac.
- Camera permission is used only to scan cmux pairing QR codes.
- Microphone and speech recognition permissions are used only when the reviewer
  chooses voice transcription in the message box.
- Photo library permission is used only when the reviewer attaches a photo to a
  terminal-agent message.

Payments:

- The iOS App Store build does not sell digital goods and does not expose Stripe,
  Stack checkout, external purchase links, or billing management links.
- The web billing surface is gated for App Store mode with
  `cmux_distribution=appstore`; direct checkout requests with that distribution
  are redirected before Stack or Stripe checkout creation.
- Direct billing portal requests with `cmux_distribution=appstore` are also
  redirected before Stack or Stripe portal session creation.
- Existing paid access from web or desktop accounts is read-only entitlement
  state in the iOS app. There is no in-app upsell or purchase call to action.

Privacy and account handling:

- Sign in supports Apple, Google, GitHub, and email code through Stack Auth.
- Push notifications are opt-in. The device token is uploaded only after the user
  enables phone notifications.
- `ITSAppUsesNonExemptEncryption` is `false`; the app uses standard platform
  networking and TLS.

Primary review path:

1. Sign in with the demo account supplied in App Store Connect.
2. For email-code sign-in, open the Mailinator public inbox URL supplied in ASC
   Review Information and enter the newest one-time code from the email subject.
3. Wait for the prepared review Mac to appear. If the ASC notes include a manual
   fallback, select Tailscale Only under Settings > Connection Method, then use
   Add Computer with the exact fallback values supplied there.
4. Open the workspace list, then open the `App Review` workspace detail.
5. Send `echo app-review-ok` from the message box.
6. Enable phone notifications and verify the opt-in prompt, then disable them
   again from the same surface.
