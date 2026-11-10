# cmux iOS Review Notes

This file is reference-only background for the team. The App Store Connect
notes come from `review-notes-asc.txt`, which every `ios-app-store.yml` run
writes to App Store Connect (`ios/scripts/asc_review_package.py sync-notes`); do
not paste this file into App Store Connect.

cmux for iOS is the phone app for cmux on the Mac. A signed-in user messages
their Chiefs (agents that run coding agents on their own Mac) and other people
on cmux, gets notified when a Chief needs them, and approves agent permission
requests.

Official App Store Connect app: Apple ID `6783338052`.

Demonstration mode: none is wired in this app. The review account reaches a
Chief on a prepared review Mac (`reviewer-setup.md`).

Reviewer access:

- Use the demo account entered in App Store Connect Review Information. Do not
  put demo credentials in this repository.
- For a Mailinator demo account, put the exact demo email in the ASC demo
  account field and put the public inbox URL in ASC notes. State that the app
  sends a one-time email code and that no Mailinator account is required.
- The reviewer does not need to own or install cmux on a Mac. Before submission,
  keep the prepared review Mac online, signed in to the same demo account, and
  running the Chief the notes name; Home reaches it through the cmux cloud, the
  default Chat Server, so no VPN or network configuration is required.
- The prepared Mac must use a dedicated review-only macOS user, no personal or
  developer credentials, and fictional names. Reset the review user after App
  Review finishes.
- Notifications are requested after sign-in and are optional.
- Face ID is used only to approve an agent's permission request.
- Microphone and speech recognition permissions are used only for voice calls
  and voice notes to a Chief, started from Siri, Shortcuts or the Action Button.

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
- Push notifications are opt-in. The app asks after sign-in, and the device token
  is uploaded only after the user allows notifications.
- `ITSAppUsesNonExemptEncryption` is `false`; the app uses standard platform
  networking and TLS.

Primary review path (the App Store Connect notes are rendered from
`review-notes-asc.txt` on every `ios-app-store.yml` run):

1. Sign in with the demo account supplied in App Store Connect: "Email me a
   code", then the newest one-time code from the Mailinator public inbox the
   notes name, then "Verify code".
2. Home lists the account's conversations. Open the Chief the notes name.
3. Send "Reply with app-review-ok" and read the Chief's reply.
