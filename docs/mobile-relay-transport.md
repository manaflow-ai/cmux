# Mobile relay transport (HostRelay Durable Object)

Status: implementing, August 2026. The replacement for iroh as the cmux
mobile transport; see `plans/` in cmuxterm-hq for the full migration plan.
Not backwards compatible with iroh clients by design.

One Cloudflare Durable Object class, `HostRelay` (`workers/mobile-relay`),
one instance per host device, id derived from a VERIFIED Stack access token
(`v2:<stackUserId>:<hostDeviceId>`). The host keeps one outbound WebSocket to
its own object; each phone keeps one WebSocket to the object of the host it
uses. The object relays opaque per-session binary frames
(`[u8 type][u32 sessionId][payload]`, first payload byte = channel tag) and
understands only small schema-validated JSON control messages (`welcome`,
`peer_joined`, `peer_left`, `refresh`, `close_session`, `bye`). It persists
nothing except a session counter; terminal replay lives in the Mac's ring
buffers, so a relay restart means reconnect-and-resume from cursors.

The wire contract's single source of truth is Effect Schema in
`workers/mobile-relay/src/protocol.ts`. `bun run generate` emits the Swift
Codable types (`Packages/Shared/CmuxRelayTransport/.../Generated/`); CI fails
on drift. The web app is not part of the protocol.

Auth (v2, direct-to-DO): the endpoint presents its own Stack access token on
the WebSocket upgrade (`x-cmux-stack-access` plus role and device headers).
The worker verifies the token against the Stack API — public project
configuration only, short per-isolate verdict cache — and derives the object
id from the VERIFIED user id, so cross-user access is impossible by
construction; a client naming a foreign hostDeviceId still lands on an object
namespaced by its own account. There is no ticket, no mint route, no shared
secret, and no web-API call anywhere on the connect path. Sessions live 1 h
past the last verified token and extend with an in-band `refresh` carrying a
current token, which the object re-verifies.

The Mac trusts none of that chain with data-plane authority: the phone's
FIRST frame on the RPC stream is `mobile.session.admit`, carrying the same
Stack token, which the Mac verifies itself end to end
(`MobileHostRelayAdmission`). One admission binds the session to the account;
every later request is credential-free, so keystrokes carry no auth bytes and
no per-request verification cost. A failed admission answers every request
with `unauthorized`, which drives the client's normal re-auth path.

Off by default, both sides. Mac: Settings > Mobile > Relay Remote Access
(`mobile.relayHost.enabled`, default false on every channel); while off the
Mac never dials. iOS: the per-Computer connection
method gains an exclusive `Relay` option that synthesizes the one
`.websocket` route. Relay and Tailscale never fall back to each other, in
either direction; a transport failure reports as a failure.

Swift pieces: `Packages/Shared/CmuxRelayTransport` (frame codec, connect
auth + admission, `RelayConnection`, `RelayHostLink`,
`RelayClientByteTransport`, the `.websocket` factory). The Mac's `MobileHostRelayRuntime` hands each relayed
phone session to `MobileHostService.acceptTransport`, which owns RPC
dispatch, event fan-out, and quotas, so the relay reuses the entire existing
mobile host path. Terminal output rides the capability-negotiated render-grid
and `terminal.bytes` event topics on the control stream; dedicated raw
terminal channels are reserved (channel tags exist) but not yet built.

Operations: `workers/mobile-relay/README.md` (deploys, dev worker; no secrets).
