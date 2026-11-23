# Browser device bootstrap

The `/app/` host sets `AcpmuxHostConfig.browserDevice: true` and supplies a
WebSocket endpoint at the page's own origin (HTTP maps to WS; HTTPS to WSS).
Native bridge and existing development hosts omit this flag.

Before connecting, browser sign-in calls
`setBrowserDeviceEnrollment({ accessToken, publicKey })` from `browserDevice.ts`.
The public key is a standard-base64 32-byte public key. Neither secret belongs in
host config, a URL, local storage or session storage. Credentials live in page
memory, so a reload needs sign-in bootstrap again.

`AcpmuxDirectClient.open()` sends `_acpmux/device_enroll` on its own socket, then
`_acpmux/device_hello`. Only the `auth: "webDevice"` acknowledgement releases
initialize, watch, list and attach. A replacement client and an internal reconnect
both present hello on their new socket, reusing the page's enrolled credential.
The daemon remains the authority for access and revocation (the protocol from
cmux#45112); this client never borrows the listener's hub identity.

On sign-out, call `clearBrowserDeviceIdentity()` and close the pane client or
reload the page. Clearing/replacing identity prevents pending handshakes and
queued operations from sending under the previous identity. Denied enrollment,
malformed acknowledgement and revocation require an explicit new sign-in. An
ordinary disconnected hello retains the enrolled credential; an uncertain enroll
does not silently mint another device. Each handshake RPC has a 30-second bound.

Errors carry `reason`: `device.identity_required`, `device.origin_mismatch`,
`device.enroll_refused`, `device.handshake_timeout`, or the daemon's refusal such
as `device.revoked` / `device.unauthorized`. The sign-in surface owns the recovery
copy. The ACP inspector redacts enrollment access tokens, returned credentials
and hello credentials.

The regression detector is `browserDevice.test.ts`, exercised with the existing
direct client and socket fixture. It covers the common failure class: authenticating
on a separate harness connection while the pane's actual/replacement connection
starts reading unauthenticated. Run on the integrated PR through `cmux-ci test`:

```sh
cmux-ci test -- bash -c 'cd webviews && bun install --frozen-lockfile && bun test src/agent-session/acpmux/browserDevice.test.ts src/agent-session/acpmux/socketToken.test.ts test/secret-wire-log.test.ts'
```
