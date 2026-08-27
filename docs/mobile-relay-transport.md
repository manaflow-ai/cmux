# Mobile relay transport (HostRelay Durable Object)

Status: implementing, August 2026. The replacement for iroh as the cmux
mobile transport; see `plans/` in cmuxterm-hq for the full migration plan.
Not backwards compatible with iroh clients by design.

One Cloudflare Durable Object class, `HostRelay` (`workers/mobile-relay`),
one instance per host device, id derived from verified ticket claims
(`v1:<stackUserId>:<hostDeviceId>`). The host keeps one outbound WebSocket to
its own object; each phone keeps one WebSocket to the object of the host it
uses. The object relays opaque per-session binary frames
(`[u8 type][u32 sessionId][payload]`, first payload byte = channel tag) and
understands only small schema-validated JSON control messages (`welcome`,
`peer_joined`, `peer_left`, `refresh`, `close_session`, `bye`). It persists
nothing except a session counter; terminal replay lives in the Mac's ring
buffers, so a relay restart means reconnect-and-resume from cursors.

The wire contract's single source of truth is Effect Schema in
`workers/mobile-relay/src/protocol.ts`. `bun run generate` emits the web copy
(`web/services/mobileRelay/generated/`) and the Swift Codable types
(`Packages/Shared/CmuxRelayTransport/.../Generated/`); CI fails on drift.

Auth: `POST /api/mobile-relay/ticket` (native Stack bearer + refresh headers,
device-registry ownership check) mints a 5-minute HMAC ticket carrying
`{userId, hostDeviceId, deviceId, role, iat, exp}`. The worker verifies the
HMAC and derives the object id from the verified claims, so cross-user access
is impossible by construction. Sessions live 12 h past the last accepted
ticket and extend with an in-band `refresh` that the object re-verifies.
Stack tokens never cross the relay socket; the tunneled RPC keeps its
per-request Stack verification on the Mac (`.relaySession` authorizes exactly
like `.stackBearer`). The ticket response's `relayUrl` is the dial target, so
the server selects the relay endpoint per environment.

Off by default, both sides. Mac: Settings > Mobile > Relay Remote Access
(`mobile.relayHost.enabled`, default false on every channel); while off the
Mac never mints a ticket and never dials. iOS: the per-Computer connection
method gains an exclusive `Relay` option that synthesizes the one
`.websocket` route. Relay and Tailscale never fall back to each other, in
either direction; a transport failure reports as a failure.

Swift pieces: `Packages/Shared/CmuxRelayTransport` (frame codec, ticket
client, `RelayConnection`, `RelayHostLink`, `RelayClientByteTransport`, the
`.websocket` factory). The Mac's `MobileHostRelayRuntime` hands each relayed
phone session to `MobileHostService.acceptTransport`, which owns RPC
dispatch, event fan-out, and quotas, so the relay reuses the entire existing
mobile host path. Terminal output rides the capability-negotiated render-grid
and `terminal.bytes` event topics on the control stream; dedicated raw
terminal channels are reserved (channel tags exist) but not yet built.

Operations: `workers/mobile-relay/README.md` (deploys, secrets, dev worker).
