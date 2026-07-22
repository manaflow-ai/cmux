# Mobile state sync v2 (delta protocol)

Status: implementing, July 2026. Replaces the invalidate-and-refetch workspace
sync between the Mac host and iOS clients. Transport-agnostic: rides the
existing framed RPC control stream and event subscription on both the legacy
TCP path and Iroh; it does not depend on Iroh work in flight.

## Problem

Today any workspace change (notification line, title, unread dot, selection)
emits `workspace.updated` with an empty payload, throttled to 80ms, and every
subscribed phone re-fetches the entire `mobile.workspace.list` response. Each
workspace row is ~0.5-1KB of JSON (including a 140-char activity preview), so
at 100+ workspaces one changed field costs ~100KB of serialization on the Mac
main actor plus ~100KB on the wire, per phone, per change burst. The phone then
diffs nothing: it replaces its whole list. The event also carries no ordering
information, so a missed edge is silent staleness until the next change.

## Design

Two collections, `workspaces` and `groups`, are synced as versioned records.

Versioning:
- `epoch`: UUID minted when the Mac's sync store is created (process launch).
  A client cursor is only meaningful within one epoch.
- `rev`: per-collection monotonic UInt64 head revision. Every change tick that
  modifies a collection bumps its head by one; all records changed in that tick
  are stamped with the new head.
- Removals are recorded as `(id, rev)` tombstones in a bounded ring (1024). A
  cursor older than the oldest retained tombstone gets a snapshot instead of a
  delta.

Wire contract (same JSON envelope and framing as every other mobile RPC):
- `mobile.sync.fetch` request: `{"collections": [{"id": "workspaces",
  "epoch": "...", "rev": 123}, ...]}`. `epoch`/`rev` omitted on cold start.
  Response per collection is either `{"mode": "delta", "from_rev": 123,
  "rev": 130, "records": [changed rows], "removed_ids": [...]}` or
  `{"mode": "snapshot", "rev": 130, "records": [all rows]}`, plus the current
  top-level `epoch`.
- Event topic `mobile.sync.delta` (subscribed through the existing
  `mobile.events.subscribe`): `{"epoch", "collection", "from_rev", "to_rev",
  "records": [changed rows], "removed_ids": [...]}`.

Client apply rule: a delta applies iff the epoch matches and
`from_rev <= local rev < to_rev`. Records are full rows keyed by id, so
overlapping frames apply idempotently. `from_rev > local rev` is a gap: the
client re-runs `mobile.sync.fetch` with its cursor and gets a delta or
snapshot. Ordering violations therefore self-heal instead of accumulating.

Startup ordering: the client subscribes to `mobile.sync.delta` first, then
fetches. A delta arriving during the fetch either overlaps (idempotent) or
gaps (repair fetch); there is no window where a change can be silently lost.

Record shapes mirror the existing `mobile.workspace.list` row fields
(snake_case), plus `sort_index` so list order syncs explicitly. Group
membership stays derived from each workspace's `group_id` on the client,
matching current behavior.

## Compatibility and negotiation

The capability check is the method itself: a new phone calls
`mobile.sync.fetch`; a Mac that does not implement it returns method-not-found
and the phone falls back to the legacy refetch loop. Old phones never call it
and keep the legacy `workspace.updated` behavior, which the Mac continues to
emit unchanged. No settings flag.

## Mac-side production

`MobileWorkspaceListObserver` already owns the change sources (tabs, selection,
groups, notifications, unread indicators) behind an 80ms latest-wins throttle.
Each tick additionally builds typed rows, applies them to the store (which
diffs by value and bumps revs only for real changes), and emits one
`mobile.sync.delta` frame per changed collection when the topic has
subscribers. The store diff replaces the current summary-hash dedup for v2
consumers; the legacy empty event keeps using the hash.

Cost model: each tick is one O(rows) typed rebuild and diff on the main actor,
bounded by the same 80ms throttle as today, and replaces per-phone full-list
serialization with one shared small frame. The activity-preview sanitizer runs
only for rows whose source notification changed.

## iOS-side consumption

A mirror store per connected Mac holds records + cursor and projects ordered
rows into the same published state the workspace list UI renders today. The
adapter negotiates v2 at connect; on event-stream loss or reconnect it fetches
with its cursor instead of reloading the full list. Foreground Mac first;
secondary Macs move to the same path once the foreground path is proven.

## Explicitly out of scope here

- Terminal byte/render-grid streaming (separate lane work; the render-grid
  path is already delta-based and well-coalesced).
- The RPC session write-stall/heartbeat hardening (next PR in this program).
- Refactors of `MobileShellComposite`/`TerminalController` beyond the minimal
  seams (new extension files, no restructuring).

## Future refinements (documented, not built)

- Fractional ordering keys to avoid N sort_index bumps on reorder.
- Per-client outbox coalescing for slow phones (today's bounded per-connection
  event queue suffices because a typical one-row delta frame is around two
  orders of magnitude smaller than the full-list refetch it replaces at a
  100+ workspace scale).
- Binary record encoding once the control stream grows an opcode envelope.
