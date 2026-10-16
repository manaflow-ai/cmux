# Encrypted phone notifications and replies

The first App Store release requires authenticated push key exchange. An older
peer without keys cannot send or receive notifications or relay replies with a
new client. Terminal attachment remains available independently of push setup.

Keys are pinned over the authenticated device connection, scoped to the account,
builds, installations, Mac device and instance. A public key from the server
directory alone does not establish trust. The push and reply endpoints for new
clients accept encrypted envelopes only; missing keys never select a plaintext
fallback.

Registration rejects missing or invalid key fields. Mac forwarding returns
`encryption_unavailable` when no trusted recipient is available. Recipient
discovery refreshes on demand, with a 30-second minimum interval. Reopen the iOS
app to retry secure pairing, then send a new notification. Unsuitable pre-release
notifications cannot be replied to, and new Macs do not drain legacy inboxes.

Key exchange starts in an owned cancellable task after attachment. It makes at
most three attempts, each with a three-second RPC deadline and bounded backoff.
Disconnecting or changing accounts cancels the exchange before peer keys are
pinned.

## Diagnostics

Mac forwarding reports a Sentry warning at most once a minute when encryption
is unavailable. iOS records fixed `pushKeyExchange*` and `pushReply*` diagnostic
events through the existing Sentry log exporter and its log budget. Backend
registration rejection sets `cmux.apns.failure_stage` to
`push_e2e_key_missing_or_invalid` on the existing Axiom trace.

These events contain failure categories, never notification or reply content,
keys, ciphertext, credentials, or device/account identifiers. Existing telemetry
consent and delivery settings still apply. Cancellation is not a setup failure.

Legacy endpoints remain for existing clients. New clients do not use them.
