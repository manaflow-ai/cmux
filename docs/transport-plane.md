# Transport plane: connection policy contract

Status: draft for the transport rewrite program, July 2026. This document is
the contract for connection lifecycle behavior across iOS client, Mac host,
and backend. It complements `docs/iroh-app-transport-architecture.md` (the
transport floor: endpoints, relays, admission, security), which this document
does not change. Where code and this document disagree, this document wins;
change the code.

## Goals as testable invariants

- **I1 (no needless reconnects).** An established, admitted session closes
  only for: transport-health failure (QUIC close, all paths dead, keepalive
  timeout), authorization change (revoke, grant expiry, sign-out), explicit
  supersede (a newer session for the same peer), or user action. App
  lifecycle events (foreground/background, tab switches, pull-to-refresh,
  presence pushes, watchdog probes) never close a session the transport
  reports healthy. Measured by the transport-lab `soak` and `bgfg`
  scenarios: involuntary-close count must be 0.
- **I2 (fast discovery).** A phone reconnects to a relaunched, reachable Mac
  in under 5 seconds when foregrounded. A revoked binding reaches affected
  devices in under 10 seconds while they hold a presence connection.
  Measured by the `mac-relaunch` scenario.
- **I3 (latency).** Typing echo p50 stays within the PR 9146 baseline
  (~15 ms sim loopback); reconnect resumes streams from cursors without a
  full refetch. Measured by the latency-trace probe.

## Decisions

**D1. One dial/close owner per Mac.** All connect, redial, and teardown
decisions for a given (account, MacPairingKey) flow through one main-actor
owner (today: `MobileConnectionRecoveryOwner` + the composite's recovery
entry points; end state: `MobileConnectionSupervisor`). No other code may
call `connect`/`disconnect`/`session.close` for that pair. Side systems
(terminal lanes, replay retries, browser streams, RPC session recycling)
may repair their own *streams/subscriptions* on the live session but may
never tear down or replace the session itself.

**D2. Evidence, not triggers.** Every signal that today triggers recovery is
reclassified as evidence fed to the owner:

| Evidence | Class | Allowed effect |
| --- | --- | --- |
| QUIC close / connection error from transport | health-fatal | redial |
| All-paths-unavailable (observed path status, sustained) | health-fatal | redial |
| Grant/lease revoked, auth failure | authz | close, no auto-redial until authz repaired |
| Host supersede close | coordination | adopt replacement, no backoff |
| Liveness silence (render-grid, event stream, RPC timeout) | health-suspect | probe, then resync; redial ONLY if transport also unhealthy or probe proves the session dead |
| Foreground, network path change, presence push, manual retry | opportunity | reconcile: dial if disconnected, probe if suspect, otherwise nothing |
| Pull-to-refresh, tab switch, view appearance | UI refresh | data refetch only; never a dial, never a teardown |

**D3. Transport-health gate.** Before any app-level evidence (health-suspect
class) escalates to a redial, the owner consults transport health for that
session (selected-path status from the session pool). A session with a
usable path gets resync (resubscribe + replay-from-cursor), not teardown.
This is the single rule that implements I1.

**D4. One backoff.** Exactly one backoff ladder per (account, Mac),
owned by the dial owner (today `MobileAutomaticReconnectBackoffOwner`).
Server Retry-After floors are respected. Opportunity evidence (manual,
foreground, network change) clears transient backoff; it never bypasses
broker cooldowns. No other layer keeps retry counters that can refuse a
dial the owner requested (pool corpse-retries and RPC connect gates are
mechanics below the owner, not competing policy).

**D5. Discovery freshness.** A dial plan is stale when it has no routes, or
its last dial failed with an unreachable/no-route class. A stale plan forces
a fresh broker discovery fetch (single-flight per peer, cooldown-respecting)
before the next dial. A presence route push or nudge for a Mac invalidates
that Mac's cached discovery snapshot. Discovery reuse windows apply only to
healthy-plan dials.

**D6. Broker pushes on binding change.** Binding replacement, revocation,
and reaper revocation fire a presence nudge to the affected device. Plain
refresh heartbeats do not. Nudge delivery is best-effort and never blocks
or fails the broker operation.

**D7. Host backpressure sheds, never kills.** The Mac host never closes a
connection because of event-queue depth on recoverable topics. Overflow
sheds per-topic with a coalesced repair signal once the queue drains;
clients repair via cursor fetch/replay/refetch. Queue-depth close remains
only for a wedged transport (write stall past deadline), classified as such.

**D8. Reconnect resumes, never rebuilds.** After redial, every stream
resumes from its cursor (state-sync v2 cursor fetch, render-grid replay
cursor, terminal byte offsets, feed refetch). Full refetch is the repair of
last resort, not the reconnect path. Remaining invalidate+refetch paths
(notification feed, secondary-Mac aggregation) migrate to cursors.

**D9. Background/foreground preserves sessions.** Backgrounding stops
nonessential work but never closes a healthy endpoint or session (already
per architecture doc). Foregrounding revalidates via probe with a fresh
deadline; deadlines burned during suspension are not death evidence
(existing `foregroundResumeEpoch` rule is the contract).

**D10. Every involuntary close is attributed.** Any session close not
requested by the user carries a named reason in the diagnostic ring on both
roles (already largely true post-8716/8834/9192). The transport-lab
scorecard treats an unattributed involuntary close as a defect.

**D11. Policy is a pure function.** The escalation decision (evidence x
connection state x transport health x backoff state -> action) lives in one
pure, exhaustively-tested type (`MobileConnectionPolicy`), not inline in the
composite. Mechanics (task management, generation guards) stay in the owner;
policy changes become one-file diffs with table-driven tests.

## Deletion targets

Once D1-D5 hold and the scorecard is clean, these band-aids are deleted or
demoted to mechanics, each removal proven by the scorecard staying clean:
ACK-driven resubscribe side channel, missed-event-window repair special
case, per-surface replay retry double-counters, foreground dual-gate
(probe + disconnected-redial as separate entry points), pull-to-refresh
cooldown bypasses, and the RPC-layer abandoned-connect registries where the
fork's dial cancellation makes them redundant.

## Verification

`transport-lab` (cmuxterm-hq `scripts/transport-lab/`) runs topology
scenarios against tagged dev builds and emits a scorecard from diagnostic
rings and container logs: involuntary-close count (gate: 0), recovery
trigger histogram, discovery convergence seconds (gate: <5 s), echo
latency p50/p95. Scenarios: `soak`, `mac-relaunch`, `bgfg`, plus the
in-app iroh release gate where applicable. The scorecard gates every
change to this plane.
