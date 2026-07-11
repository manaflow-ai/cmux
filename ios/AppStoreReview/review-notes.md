# cmux iOS Review Notes

cmux for iOS is a companion app for the cmux macOS terminal. It lets a signed-in
user pair with their Mac, view workspaces, receive terminal notifications, and
send input to an active terminal session from iPhone or iPad.

Reviewer access:

- Use the demo account entered in App Store Connect Review Information. Do not
  put demo credentials in this repository.
- After sign-in, use the pairing flow shown in the app. Pairing can be tested
  with a prepared review Mac, or with a manual pairing code supplied in the
  Review Information notes for the submitted build.
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
- Existing paid access from web or desktop accounts is read-only entitlement
  state in the iOS app. There is no in-app upsell or purchase call to action.

Privacy and account handling:

- Sign in supports Apple, Google, and email code through Stack Auth.
- Push notifications are opt-in. The device token is uploaded only after the user
  enables phone notifications.
- `ITSAppUsesNonExemptEncryption` is `false`; the app uses standard platform
  networking and TLS.

Primary review path:

1. Sign in with the demo account supplied in App Store Connect.
2. Pair with the prepared Mac or enter the supplied manual pairing code.
3. Open the workspace list, then open a workspace detail.
4. Send a short terminal input from the message box.
5. Enable phone notifications and verify the opt-in prompt, then disable them
   again from the same surface.
