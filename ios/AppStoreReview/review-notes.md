# cmux iOS Review Notes

cmux for iOS is a companion app for the cmux macOS terminal. It lets a signed-in
user pair with their Mac, view workspaces, receive terminal notifications, and
send input to an active terminal session from iPhone or iPad.

Official App Store Connect app: Apple ID `6783338052`.

Reviewer access:

- Use the demo account entered in App Store Connect Review Information. Do not
  put demo credentials in this repository.
- After sign-in, use the Add Computer flow shown in the app. Pairing can be
  tested with a prepared review Mac after joining the supplied Tailscale network
  and entering the exact Name, Tailscale Host, and Port values supplied in the
  Review Information notes, or by scanning a generated QR/link whose ticketed
  route is reachable from the same review network path.
- The reviewer does not need to own or install cmux on a Mac. Before submission,
  append the prepared review Mac details below directly into App Store Connect:
  - Name: `App Review Mac`
  - Host: `<TAILSCALE_MAGICDNS_OR_100_X_ADDRESS>`
  - Port: `<CMUX_MOBILE_HOST_PORT>`
  - Tailscale access: `<TAILSCALE_REVIEW_ACCESS>`
  - Review contact: `<REVIEW_CONTACT_EMAIL>` / `<REVIEW_CONTACT_PHONE>`
- The prepared Mac must use a dedicated review-only macOS user, no personal or
  developer credentials, a safe `App Review` workspace, and a network route
  restricted to the cmux mobile host port. Revoke the credentials and reset the
  review user after App Review finishes.
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
2. Tap Add Computer.
3. Install Tailscale from the App Store and sign in with the supplied review
   access first.
4. Enter the supplied Name, Tailscale Host, and Port values, then tap Pair. If a
   generated ticketed QR/link route is reachable after joining the supplied
   Tailscale network, Scan QR Code can be used instead.
5. Open the workspace list, then open the `App Review` workspace detail.
6. Send `echo app-review-ok` from the message box.
7. Enable phone notifications and verify the opt-in prompt, then disable them
   again from the same surface.
