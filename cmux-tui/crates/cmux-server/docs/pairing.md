# Server enrollment

Start enrollment on the server:

```sh
cmux server pair --name "Build host"
```

Enter the displayed code in Add Server in the signed-in cmux app. Compare the
four check words before approving. The existing backend approval checks the
person's team rights and registers the server's install key. The server waits
for the pushed result and saves the returned host, team, user and install IDs.

`cmux server pair status --json` reads the local enrollment record, including
before installation. Its `state` is one of:

| State | Fields | Meaning |
| --- | --- | --- |
| `unpaired` | none | No completed local enrollment or pending attempt |
| `pending` | `expires_at` | An approval code is awaiting a recorded result |
| `indeterminate` | `retry_not_before` | A begin request may have succeeded, but its reply was lost |
| `paired` | `host`, `team`, `user`, `install` | A pushed approval was saved locally |
| `network_pending` | The paired IDs and public `network` locator | Approval reserved a network identity; registration needs confirmation |

These states describe enrollment. Transport reachability and serving roles have
their own health. An enrollment record is not an execution grant.

## Enroll in the selected network

When the approving human selects a network, the pushed result includes a
short-lived private invitation bound to this server's existing install and
WireGuard public keys. The daemon persists it before contacting the network
service, redeems it with a fresh install-key signature, then confirms the
authoritative tenant, mesh, device and both keys with a signed policy read.
Neither request needs an account credential. HTTPS origins are validated;
redirects and unbounded responses are refused.

Until confirmation, status is `network_pending` and the identity cannot be
exported to a link. Repeat `cmux server pair` to resume. After a lost enrollment
reply, the reserved device locator permits a signed recovery read even after
the invitation expires. An unavailable service, mismatched binding or revoked
identity leaves the record pending; the daemon does not silently restart basic
pairing or replace its keys. Confirmation removes the saved invitation and
returns `paired` with `network.state` set to `registered`.

Registration records identity only. Applying current peer/port policy,
confirming the backend binding and enabling serving roles remain separate.
Chief's current pairing consumer refuses network invitations; use the server
pairing flow for network enrollment.

## Use the enrolled transport identity

After enrollment, initialize a separate link state directory with the private
record's absolute path, then start that link explicitly:

```sh
cmux link init --state-dir /path/to/server-link --server-identity /path/to/pairing/identity.json
cmux link ensure --state-dir /path/to/server-link --session-socket /path/to/cmux.sock
```

The link uses the enrolled install ID and WireGuard key directly from the
private record. It creates no second key file and refuses an existing link
identity or a conflicting `--install`. Both processes must run under the OS
account that owns the record. `link status` reports the public key actually
loaded by the running mesh. A changed record cannot silently retarget a live
link; choose a separate state directory or stop it explicitly.

Peer admission and the receiving daemon's remote-entry policy still apply.
The current carrier needs explicitly configured peers and direct reachability;
automatic server peer-map/relay integration remains separate. Paired daemon
installs retain their narrow backend grants and cannot mint Cloud dial tokens.

When this link receives a peer-map update, removing a peer or changing the
install, user or team assigned to its key closes its incoming and outgoing
paired daemon and owner-session connections before the WireGuard peer is
removed. Pending handshakes also check the current peer map; an older snapshot cannot reopen a
revoked identity. Endpoint-only changes keep the same identity connected. A
failed overlay update keeps revoked identities blocked while the next reload
retries the network change. Revoking a pending outgoing dial cancels its connect
and returns `not_authorized` before any service hello is sent.

## Progress output

For `pair --json`, public progress objects go to stderr and the final result
goes to stdout. A validated HTTPS `verification_uri` from the selected API is
included when available and preserved on resume. Machine fields, IDs and diagnostic codes are invariant; human
instructions and status labels follow `LC_ALL`, `LC_MESSAGES` or `LANG` in the
nine supported macOS languages. The default API is
`https://cloud-api.cmux.dev`; `--api-origin` accepts a canonical HTTPS origin.
Redirects, userinfo, paths, queries and fragments are refused.

## Recovery and private state

State lives at `pairing/identity.json` under the server layout's state directory.
One file lock serializes enrollment. ES256 and WireGuard keys remain stable
across retries. The known pending response is saved before waiting, so running
the same command resumes the same code after a disconnected wait or restart.
An optional `--idempotency-key` also binds that attempt; a different key or API
origin cannot retarget it.

A begin request whose reply was lost is left indeterminate through the maximum
code lifetime and clock-skew allowance. The client does not issue another begin
while that code could still be active. A code that expires requires another
explicit pairing attempt and approval. Backend host records are owned by the
backend; local expiry does not revoke them.

On Unix, the identity directory and file must be private to the current user
(0700 and 0600), with symlinks refused. On Windows, private keys and the pending
collection response or network invitation use current-user DPAPI with UI disabled, rather than
machine-wide protection. See Microsoft's
[CryptProtectData contract](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata).
Public status, progress, debug output and error messages omit key material and
the collection secret and invitation. Schema 2 holds pending/registered network
state; existing schema-1 basic enrollment records remain readable. Unix storage
uses private file permissions; it does not add encryption. The collection secret travels only in the WebSocket subprotocol
header, which is marked sensitive.

## Protocol ownership

General servers and Chief hosts use
`cmux_server_core::pairing::enrollment` for the environment-bound begin request,
RFC 7638 thumbprint, check words and pushed-result validation. The server's
network adapter bounds HTTP and WebSocket messages and waits against one
deadline. It does not poll for approval.

`server.pair.begin` and `server.pair.status` retain their existing catalog
owners. Approval remains a signed-in human operation; no MCP approval surface,
caller-supplied actor authority, App grant or remote execution grant is added.
