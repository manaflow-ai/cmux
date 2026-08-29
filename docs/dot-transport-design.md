# dot: Durable Object transport (default phone↔Mac transport)

Status: implemented in the tagged Mac and iOS runtimes; deploy and dogfood are
the remaining rollout steps.
Owner directive: replace iroh as the default transport with a Cloudflare
Durable Objects implementation. Acceptance: no reconnects, no disconnects,
initial connection ≤2s, secure; verified by a 60-minute engaged iOS simulator
soak.

## Why a DO relay

Every documented failure class of the iroh stack (relay credential expiry and
rotation, online admission races, home-relay discovery staleness, QUIC path
migration flaps, NAT traversal) exists because both peers must agree on a
meeting point and keys out of band. A Durable Object *is* the meeting point:
both sides dial out over standard `wss` to a stable, account-scoped object.
There are no relay passes to mint or rotate, no discovery records to refresh,
no inbound connectivity anywhere. The transport inherits exactly two failure
modes — a TCP/TLS path drop and a DO restart — and both are absorbed by the
resume layer below without surfacing a session disconnect.

This extends the settled control-plane v2 direction (issue 10795: per-account
presence DO WebSocket opened at t=0) to the data plane.

## Topology

One `MacRelay` DO instance per (account user, adopted Mac app identity):
`relay:user:<userId>:relay:<acceptorEndpointIdentity>`, hosted in
`workers/presence` alongside `TeamPresence` (new binding + appended migration;
auth code shared). The physical Mac device ID remains a grant/admission claim,
but does not own the relay slot, so tagged app instances on one Mac cannot
supersede each other.

- The Mac keeps ONE standing "host leg" WebSocket to its own relay DO.
- Each phone opens one "client leg" to the same DO id (it already knows the
  Mac's adopted endpoint identity from the stored route / pair grant).
- The DO forwards binary frames between the host leg and client legs; it
  routes on a fixed header and never reads payloads.
- A fresh leg announces its new leg id. A dropped socket emits no offline event
  while resume is possible, preventing a transient network loss from closing
  the encrypted session; a new leg id causes the clients to re-handshake.

## Wire protocol (`dot/1`)

Text frames = control JSON, ≤4 KiB (mirrors `cmux-tui/relays/cloudflare-do`
`MAX_CONTROL_MESSAGE_BYTES`): `hello`, `hello.ack`, `ping`/`pong` (app-level,
timestamped — these are the soak's liveness metric), `auth.refresh`,
`resume.ok`/`resume.failed`, `peer.online`/`peer.offline`, `error`.

Binary frames = data: `[u8 ver=1][u8 kind][u32be legId][u64be seq]` + payload.
Payload bytes are the existing mobile dialect envelope (`cmux/mobile/1` codec
reused verbatim as a data contract), E2E-encrypted (below). Limits copied from
the reviewed Rust relay: per-leg outbound queue ≤256 frames / 2 MiB;
oversized ⇒ leg close with protocol error.

## No-disconnect contract (resume layer)

Sequence numbers per direction per leg. The DO keeps an in-memory replay ring
per destination leg (≤256 frames / 2 MiB). A dropped WS redials with the leg's
resume key (random 32 B minted at first hello, persisted in the socket
attachment) plus the last delivered seq; the DO replays the gap and the peer
never observes the blip. Session-level state machines on both apps only
surface a disconnect if resume fails past a 30 s grace.

DO restart (deploy/eviction) loses rings: legs get `resume.failed` and
re-handshake — the one visible-reconnect case, deploy-correlated, absent
during any soak. Hibernation is compatible by construction: attachments carry
all routing state; rings only hold data while a peer is actively sending,
which prevents hibernation anyway.

Client legs port the proven `chatmux-relay` watchdogs: clock-jump detection
(wall vs monotonic delta >30 s ⇒ socket presumed dead after suspend) and
read-liveness (no inbound for 3×keepalive+grace ⇒ redial now, backoff reset).
Keepalive: WS-level ping every 20 s plus app-level ping/pong every 25 s
end-to-end through the peer.

## Security

- Both legs authenticate at connect with the Stack access token
  (`Authorization: Bearer`), verified at the edge exactly like
  `workers/presence/src/auth.ts` (`verifyRequest`); the DO receives only
  verified headers. DO id derivation happens *after* auth, so unauthenticated
  requests cannot materialize objects.
- A leg's auth deadline is capped by token `exp`. Clients push `auth.refresh`
  with a fresh token in-band before expiry (verified against Stack, pinned to
  the same user id); an alarm closes legs past deadline + grace. Long-lived
  connections therefore never outlive revocation windows — this replaces the
  legacy 15-minute stream teardown (which would violate the no-reconnect
  contract) with same-strength auth.
- Client legs additionally present the Mac-side pairing authorization; a phone
  the Mac has not paired/granted is refused at hello by the host leg
  (fail-closed, mirrors today's grant gate).
- E2E encryption over the relay: payloads are AEAD-sealed (ChaChaPoly via
  CryptoKit) under keys from an X25519 ECDH bound to the existing pairing
  trust, HKDF with hello transcript binding, so Cloudflare carries ciphertext
  only — parity with iroh's E2E property. (Exact key-material binding depends
  on the pairing artifacts; see implementation notes.)

## Connect-time budget (≤2 s)

TLS+WS to Cloudflare edge (~50–150 ms) + DO wake (~10–50 ms) + edge auth
(cached verify ~0, cold ~300 ms) + hello/E2E handshake (1 relay RTT). Typical
well under 1 s; worst-case cold path far inside 2 s. Both apps open the leg as
the first network action (t=0 rule from the settled design).

## Default flip

`cmux.dot.enabled` defaults TRUE on both platforms; the iroh/irx runtimes are
not started in dot mode (`cmux.irx.enabled` + legacy iroh gates default
FALSE, kept as explicit-revert switches). Loopback/UITest fallback transports
keep working unchanged. Full source erasure of the iroh trees stays with the
teardown lane (PR 10859); this branch removes iroh from the *runtime* default
path.

## Rollout

Dev: deploy to `cmux-presence-dev` (workers.dev) or a per-dev isolated worker
via `workers/presence/scripts/deploy-dev.sh`; apps resolve the base URL with
the existing `CMUX_PRESENCE_BASE_URL` precedence. Prod: `presence.yml`
workflow (manual dispatch) after merge.

## Verification

`scripts/dot-soak.py` (adapted from `scripts/irx-soak.py`): 60-minute engaged
soak, isolated simulator + tagged Mac, criteria: 0 session disconnects, 0
session reconnects, 0 leg redials, initial connect ≤2 s, app-level pongs
uninterrupted (max gap bounded), typed input round-trips with screen-change
evidence. Journals: Mac `/tmp/cmux-dot-journal-mac-<tag>.jsonl`, iOS app
container `Documents/dot-journal.jsonl`.
