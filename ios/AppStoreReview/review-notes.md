# cmux iOS Review Notes

cmux for iOS is a companion app for the cmux macOS terminal. It lets a signed-in
user connect to their Mac, view workspaces, receive terminal notifications, and
send input to an active terminal session from iPhone or iPad.

Official App Store Connect app: Apple ID `6783338052`.

Reviewer access:

- Use the demo account entered in App Store Connect Review Information. Do not
  put demo credentials in this repository.
- The reviewer does not need to own a Mac, install cmux on a Mac, install a VPN,
  or install a third-party networking app. We keep a prepared review Mac online,
  signed in to the same demo account, and running a safe session.
- After sign-in and onboarding, the first connection screen shows a `Continue on
  This Device` section. Tap the session named `App Review` to connect through
  cmux's built-in encrypted device connection.
- Before submission, append a monitored review contact directly in App Store
  Connect: `<REVIEW_CONTACT_EMAIL>` / `<REVIEW_CONTACT_PHONE>`.
- The prepared Mac uses a dedicated review-only macOS user with no personal or
  developer credentials. Revoke the demo access and reset that user after App
  Review finishes.
- The app may request Local Network permission to improve direct connectivity
  when the iPhone or iPad and Mac are on the same network. Remote review access
  does not require the reviewer to join the Mac's network.
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
- The same-account handoff stores bounded workspace and session summaries needed
  to display live sessions. Summaries include workspace titles, which may be set
  by the user or a terminal program. No separate transcript, prompt, or terminal-
  output fields are uploaded for discovery.
- `ITSAppUsesNonExemptEncryption` is `false`; the app uses standard platform
  networking and encryption.

Primary review path:

1. Sign in with the demo account supplied in App Store Connect.
2. Complete the short onboarding flow.
3. On the first connection screen, find `Continue on This Device`.
4. Tap the `App Review` session. The app connects to the prepared review Mac and
   opens the workspace.
5. Send `echo app-review-ok` from the message box.
6. Confirm the terminal prints `app-review-ok`.
7. Enable phone notifications and verify the opt-in prompt, then disable them
   again from the same surface.
