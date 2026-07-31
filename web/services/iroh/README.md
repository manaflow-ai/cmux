# Iroh trust broker

The broker is scoped to the authenticated Stack `user.id`. Team membership and
the legacy team device registry never grant Iroh discovery or pairing access.

Registration signatures may carry the native Iroh `watch_addr` shape, but the
server strips every direct/private address before repository persistence. Direct
paths stay device-local or move endpoint-to-endpoint after admission. The broker
persists and publishes only exact managed relay URLs. Endpoint or
identity-generation replacement requires explicit revocation and reapproval; a
signature from only the proposed new key cannot replace an active binding.

A signed registration may publish `directPorts` with independent IPv4 and IPv6
UDP ports. The broker stores only those bounded ports, never a private address,
and returns them as `direct_ports` only inside the authenticated same-account
binding catalog. Clients combine a family-matching port with locally known
addresses after EndpointID authentication. Legacy registrations omit the field
and clear any previously published ports on their next signed refresh.

`relay_fleet` is the server-configured connection preset/allowlist. It is not a
peer address. Each peer's published `relay_url` comes from its signed
`watch_addr` payload and must match that allowlist. Discovery defensively
filters older rows to the same relay-only policy.

Discovery runs the user-scoped retention cleanup before reading. It removes
expired hints from binding JSON, challenges more than 24 hours past expiry or
consumption, and pair/relay audit rows more than 30 days beyond their useful
window. Revocation clears hints immediately. Once a revoked binding is at least
30 days old and its pair/relay audit rows have reached their own retention
limit, cleanup deletes the binding's EndpointID, device/app UUIDs, tag, and
display name. The hourly `/api/internal/iroh/retention` cron applies the same
policy across inactive accounts; responses also filter expired hints
defensively.

Binding lifecycle changes additionally fire a best-effort `iroh-binding-changed`
nudge at the presence worker (`POST /v1/presence/nudge`, shared-secret header
`x-cmux-nudge-secret`), targeted at the AFFECTED binding's device id and tag, so
a subscribed device re-checks broker state within seconds instead of on its next
poll. Exactly three paths nudge: user revocation, slot reincarnation (a signed
registration that re-keys an existing (user, device, tag) slot to a new binding
id), and the stale-binding reaper below. Plain signed refresh heartbeats and
genuinely new slots never nudge, so refresh cadence cannot become nudge churn.
The hook is env-gated by `CMUX_PRESENCE_NUDGE_URL` plus
`CMUX_PRESENCE_NUDGE_SECRET` (either absent disables it entirely) and strictly
fail-open: delivery has a ~2s budget, errors are swallowed and logged as counts,
and a presence-worker outage can never fail or block a broker mutation. Because
the presence worker shards Durable Objects by team, the nudge fans out to the
device's registry teams (`devices.team_id`, capped at three) plus the user id as
the solo-account fallback; a wrong-team candidate 404s harmlessly. The worker
verifies the shared secret, then still enforces the device's presence owner pin
against the asserted user id.

The retention cron also REAPS stale active bindings. Each dev build occupies its
own (user, device, tag) slot, and the shared dev account once accumulated 250+
of them, hit the 256 active-binding sanity cap (pinned to the iOS discovery wire
limit, never to be raised), and 409'd every new registration. The reaper
soft-revokes (sets `revoked_at`, through the exact same helper as user
revocation: hints and direct ports cleared, live pair grants revoked, LAN
rendezvous generation rotated) any active binding whose `registered_at`
high-water mark AND `last_seen_at` are BOTH older than its shape's TTL.
Shape rule: a binding whose tag exactly matches a release-channel tag
(`default`, `stable`, `rc`, `nightly`, `staging` — stable builds register
`default` on both platforms) gets the long TTL,
`CMUX_IROH_STALE_RELEASE_BINDING_TTL_HOURS` (default 1080h = 45 days); every
other tag is a dev-style tagged build and gets the short TTL,
`CMUX_IROH_STALE_DEV_BINDING_TTL_HOURS` (default 72h). Slugged channel builds
(a slugged rc/nightly/staging registers its bare slug) intentionally land in
the dev bucket: they are transient dogfood installs, indistinguishable from dev
tags on the wire, and the conservative failure mode is reaping a dogfood build
early, never a stable one. Reaping is safe even if it misfires: newest-wins
slot re-key semantics let a reaped device re-register IN PLACE on its next
launch or signed refresh, and a still-running instance receives the reaper's
nudge and re-registers within seconds. Reap batches are bounded (500 rows per
run by default), re-check staleness under `FOR UPDATE SKIP LOCKED` inside the
per-user binding advisory lock and account-deletion fence, and record
`revoked_reason` as `stale_development_binding` or `stale_binding_retention`.

The LAN rendezvous key is HMAC-derived from an independent random server secret,
the exact Stack user id, and an account generation. Discovery reads active
bindings and that generation in one transaction under the same account lock as
registration and revocation, so it cannot mix tuples from opposite sides of a
revocation. Every successful binding revoke increments the generation in the
revocation transaction. Sign-out callers must invoke the authenticated revoke
route with their captured binding id before discarding the Stack credential.

Postgres advisory locks make the authoritative limits concurrency-safe: six
challenges per device per ten minutes, 32 outstanding challenges per account,
32 active bindings per account, eight active bindings per physical device, 60
pair grants per account per hour, three relay mints per endpoint per ten
minutes, 12 relay mints per endpoint per day, and 100 relay mints per account
per day. A relay reservation remains active for 60 seconds, then the next
account-scoped reservation marks it expired before applying those quotas. The
optional Vercel Firewall rule is defense in depth. A tagged-build
device-limit override requires a server flag, an exact authenticated user-id
allowlist match, and an exact deployment-environment allowlist match; it never
raises the 32-binding account limit and records an audit marker on the binding.

Registration bootstraps a relay credential only when it creates a binding.
Signed refreshes of the same binding return `relay.status = "not_requested"`;
clients retain their existing credential or use the dedicated relay-token route
when its refresh window arrives. Platform is part of the immutable binding
identity and requires explicit revocation before it can change.

The n0-hosted relay minter is an optional compatibility path. When
`CMUX_IROH_MINT_URL` and `CMUX_IROH_MINT_HMAC_SECRET_B64` are absent, initial
registration returns `relay.status = "unavailable"` without rolling back the
binding. Current clients obtain endpoint-bound credentials for the self-hosted
fleet from `/api/relay/token`.

Every user-scoped mutation acquires the account-deletion advisory fence before
any Iroh lock. If the deletion tombstone wins, no challenge, binding, grant, or
relay audit state can be created. If an Iroh mutation wins, account deletion
waits for that transaction and then removes its rows. Pair grants re-read and
lock both exact signed peers at audit insertion, requiring an iOS initiator and
a pairable Mac acceptor. Relay credentials are returned only after a second
locked active-binding check following the external mint.

Registration stores the earliest managed-relay expiry in
`path_hints_next_expiry`. The hourly cleanup uses that indexed scalar and
bounded 500-row `FOR UPDATE SKIP LOCKED` batches for relay hints, challenges,
audit rows, and revoked bindings. Concurrent cron workers can cooperate without
a full-table JSON scan.

The `20260710120000_iroh_server_path_privacy` migration clears pre-policy broker
hints and removes existing Iroh route bodies from the legacy device registry.
Hosts republish sanitized EndpointID/managed-relay routes on their next refresh;
non-Iroh routes are preserved in order.

The `20260710113000_iroh_relay_reservation_expiry` migration added the expanded
status constraint with `NOT VALID` so its `ACCESS EXCLUSIVE` lock was released
without scanning existing rows. The later
`20260718120000_iroh_relay_status_validation` migration validates it after the
schema change was recorded:

```sql
ALTER TABLE "iroh_relay_token_issuances"
  VALIDATE CONSTRAINT "iroh_relay_token_issuances_status_check";
```
