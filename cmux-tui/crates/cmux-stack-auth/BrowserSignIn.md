# Browser account enrollment integration

`BrowserSignIn` reuses the existing Stack email-code exchange. It does not import an
app session or read credentials from the daemon, environment, disk or keychain.
The browser presents its own account to the existing device enrollment check.

## Listener adapter

Admit only `_acpmux/browser_sign_in_start` and `_acpmux/browser_sign_in_complete`
beside the existing device enrollment methods before initialization. These methods
do not initialize or authorize a session. Keep a single `Option<BrowserSignIn>` on
that connection; drop it when the connection closes.

- Start takes `{email, publicKey}`. Clear the prior pending attempt first, then call
  `BrowserSignIn::start(stack, origin, owner_user_id, public_key, email, callback_url)`.
  Store its result and return `{expiresIn: 300}`. The browser generates its own
  32-byte device key and sends its standard-base64 public half.
- Complete takes `{code}`. Take the pending attempt before awaiting `complete`.
  Return the serialized `BrowserEnrollment`: `{accessToken, publicKey}`. Failures
  consume the attempt; retry starts a new explicit sign-in.

The listener supplies its trusted owner account ID and deployment's existing Stack
configuration and email-link callback URL. None comes from the request. Check the
HTTP/WebSocket Origin against the listener's configured origin before either call;
the transaction additionally binds completion to that origin. Only HTTPS or a
loopback HTTP origin is accepted. Apply the listener's existing bounded pre-auth
connection/request budget. A challenge expires after five minutes, including its
network requests; no background task or unbounded process-wide challenge map is needed.

The email's visible code is trimmed and lowercased before its opaque nonce is
appended, as in `CMUXAuthMagicLinkCode`. Stack verifies the code, and `/users/me`
must name the listener's owner; restricted or anonymous accounts cannot complete.
Do not replace device enrollment's current account check: the owner may change
while the interactive sign-in is in progress.

## Browser handoff

Keep the returned credential only in page memory. Call
`setBrowserDeviceEnrollment({accessToken, publicKey})` before opening the pane
client. The pane client performs device enrollment and hello on its socket.
Account sign-in alone never authorizes an RPC. A denied/revoked device requires a
fresh explicit sign-in; do not automatically recover by borrowing another token.

On sign-out, call `clearBrowserDeviceIdentity()` **and close the authorized pane
client** (or reload). Clear any pending login connection too. No refresh token is
returned by this helper, and no token should be logged, placed in a URL, saved to
browser storage, or written to a capture artifact.

## Verification

On the integration PR's exact pushed head, run on the fleet:

```sh
cd cmux-tui
cmux-ci test --setup rust -- cargo test -p cmux-stack-auth --test browser_sign_in
```

The fake Stack exercises the wire exchange, visible-code normalization, owner
matching, origin mismatch, expiry, invalid keys, safe errors and the absence of
refresh tokens from the browser response. It does not prove deployed Stack
configuration or interactive email delivery. Capture the full flow separately
using a test account's ordinary email-code sign-in, never a daemon account secret
or a harness-injected enrolled device.

Prior art: `cmux-platform/src/server/auth/Surface.ts` and `Http.ts` serve install
challenge/redeem, not interactive human login (development-only in the inspected
tree `1c739cd18fda`). `cmux-stack-auth` already owns the human email-code exchange.
