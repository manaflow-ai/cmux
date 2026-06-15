# Local-first sync for cmux (and the iOS device list as its first consumer)

Status: proposed. Phase 1 ships the generic sync substrate plus the device-list
consumer behind a flag, with the Aurora registry kept intact as a fallback.

This document is the deliverable. The code in this PR exists to prove the
protocol is real and shippable, not to finish the feature. Read the protocol
section before the code.

## 1. Problem and goals

Today the iOS device list (the "device tree": device → tagged app instance →
workspaces) is assembled from three uncoordinated sources:

1. **Aurora registry** (`devices` / `device_app_instances`, `GET /api/devices`)
   is the durable list source. It is a blocking HTTP fetch on every open of the
   sheet. Cold start shows nothing until that round trip returns.
2. **Presence DO** (`workers/presence`, `presence.cmux.dev`) is a realtime
   overlay: a per-team `TeamPresence` Durable Object that knows online/offline
   and pushes fresh routes over a WebSocket. It is already live (#5792).
3. **Local `MobilePairedMacStore`** (`paired-macs.sqlite3`, raw SQLite3) is the
   phone's local memory of paired Macs and is used as a fallback when the
   registry is unreachable.

Lawrence's four requirements:

1. The device list is **driven by the per-team presence DO**, not the Aurora
   registry. The DO becomes the cloud source of truth for identity + routes +
   owner + presence as seen by the client.
2. A **local SQLite cache backs the list so startup is instant**: render from
   local SQLite with zero network on the launch path, then reconcile against the
   DO in the background and update the UI live.
3. Use **the most standard SQLite thing**: the repo already standardizes on the
   raw SQLite3 C API in `CmuxMobilePairedMac`. Extend that pattern; no new GRDB
   or FMDB dependency.
4. The **sync protocol must be general and extensible**, not device-list
   specific. Device-list is the first consumer of a reusable local-first sync
   layer that future features (workspaces, settings, notifications) plug into.

Non-goals for phase 1: ripping out Aurora, moving every existing collection onto
sync, offline write replay for device-list (device-list is read-mostly on the
phone), multi-team simultaneous sync. These are designed for but not all built
now (see §12 phasing).

The hard constraint that shapes everything: **the presence DO is a running,
deployed, live service.** Any change to it must be additive and tolerant of the
old data shape during the gradual cross-colo rollout window
(`docs/presence-service.md`, "Upgrading running Durable Objects"). The protocol
below is designed so the DO change in phase 1 is purely additive.

## 2. The big idea: a generic syncable-collection substrate

Define one local-first sync layer with three pieces that know nothing about
devices:

- **Wire protocol** (`sync/v1`): a snapshot+delta stream over the existing
  presence WebSocket transport, carrying opaque per-record payloads tagged by a
  `collection` name, each record stamped with a monotone `rev`, an `updatedAt`,
  and a tombstone flag. A `cursor` lets a returning client resync only what
  changed.
- **Local store** (`CmuxSyncStore`): one raw-SQLite3 database with a single
  generic `sync_records` table keyed by `(collection, recordId)`, plus a
  `sync_cursors` table. Typed per-collection facades read/write through it. This
  mirrors `MobilePairedMacStore` exactly (actor, `Storing` protocol seam, error
  enum, `PRAGMA user_version` lazy migrations, `BindValue` binder).
- **Collection registry** (the extensibility contract): a `SyncCollection`
  descriptor binds a string `name` to a `Codable` record type and a merge rule.
  Registering a collection gets it local persistence, snapshot/delta ingestion,
  cursor tracking, and live UI updates for free. Device-list is the first
  registration; workspaces/settings/notifications are future registrations with
  no protocol or store changes.

The device list becomes: a `devices` collection whose records are `DeviceRecord`
value types. The DO owns the authoritative copy; the local SQLite cache is a
materialized view; the UI renders the cache and is invalidated by deltas.

```
  Mac host ──heartbeat(routes,identity)──▶  TeamPresence DO  ──sync/v1 snapshot+delta──▶  iOS
                                            (authoritative                                 │
                                             durable records,                              ▼
                                             rev-stamped)                            CmuxSyncStore
                                                                                    (sync_records,
                                                                                     sync_cursors)
                                                                                          │
                                                                                          ▼
                                                                                   DeviceListView
                                                                              (instant from SQLite,
                                                                               live-updated by deltas)
```

## 3. The sync protocol (`sync/v1`)

This is the part to get right. It is deliberately small and CRDT-free; the
trade-off analysis for that choice is in §7.

### 3.1 Identity of a syncable record

Every synced thing is a `SyncRecord`:

| Field        | Type    | Meaning |
|--------------|---------|---------|
| `collection` | string  | logical table, e.g. `"devices"`. Registered name. |
| `id`         | string  | stable record id, unique within `(team, collection)`. |
| `rev`        | integer | per-`(team, collection)` monotone version. Authoritative. |
| `updatedAt`  | number  | epoch ms the DO last wrote this record. Tiebreak/debug only. |
| `deleted`    | boolean | tombstone. A deleted record still has a `rev` and is broadcast so clients can drop it; it is GC'd from durable storage after a retention window. |
| `payload`    | object  | opaque-to-transport, collection-typed JSON body. The transport never inspects it. |

`rev` is the spine. It is **not** a per-record counter; it is a single
**per-(team, collection) logical clock** that the DO increments on every write
to that collection and stamps onto the written record. So within a collection,
`rev` values are unique and strictly increasing in write order. This gives three
properties:

- **Total order within a collection.** The DO is a single-threaded actor, so
  writes to one collection are serialized and `rev` is a true logical clock.
  Clients see a linearizable history of each collection.
- **Idempotent, reorder-safe application per record.** Applying a record with
  `rev <= localRev(id)` is a no-op. Duplicate deltas (possible across a reconnect
  that overlaps an in-flight broadcast) converge: the client keeps the highest
  `rev` seen per record id.
- **Catch-up by cursor.** A returning client sends one cursor per subscribed
  collection; the DO replies with everything newer. But the cursor advance rule
  is subtle, and getting it wrong loses records. §3.2a pins it down.

Note the cursor is per collection, not per record. A returning client sends one
cursor per subscribed collection and the DO replies with everything newer.

### 3.1a The cursor is a contiguous-prefix watermark, advanced per frame, not per record

The cursor is **the rev below which the client has applied every record in the
collection**, not "the max rev applied." Those differ, and only the first is
safe. The DO derives records per device from a shared collection clock, so a
single logical change can mint several revs across several records. If the client
advanced its cursor to `max(rev)` after applying record `rev=185` but had not yet
received `rev=184` for a different id, it would send `cursor=185` on reconnect,
the DO would send only `rev > 185`, and `rev=184` would be lost forever.

Two rules close the gap, and the protocol relies on both:

1. **The DELTA FRAME, not the record, is the atomic cursor-advance unit.** A
   `sync.delta`/`sync.snapshot` frame carries a `rev` field = the collection head
   the frame brings the client up to, and the frame's `records` are *every*
   record in `(cursor, frame.rev]` that the DO has (contiguity is the DO's
   responsibility: it lists by rev and never skips). The client applies the whole
   frame's records, then advances `cursor = frame.rev` **only after the frame is
   fully applied in one local SQLite transaction**. A partially-applied frame
   never advances the cursor. So the cursor only ever names a rev below which the
   client provably has everything.

2. **The DO emits frames in rev order and never skips a rev for a subscribed
   collection.** Because the DO is single-threaded per team, it can scan
   `synced:<collection>:*` ordered by rev and emit a contiguous run. A delta
   broadcast triggered by one write carries exactly the records that write
   changed, and their revs are the contiguous tail of the clock, so a client at
   `cursor = head-1` receiving them lands exactly at `head`.

This makes "send everything with `rev > cursor`" correct, because `cursor` is now
a true watermark, not a high-water mark with holes below it.

### 3.2 Wire messages

The transport is the existing presence WebSocket (`/v1/presence/subscribe`,
extended; see §5). Frames are JSON objects with a `type`. The presence message
types (`snapshot`/`online`/`offline`/`seen`/`routes`) are unchanged and continue
to flow. Sync adds a new namespace under `type: "sync"`:

Client → server (sent as WS text after connect, or as query params on connect):

```jsonc
// Subscribe to collections with the cursors I already have.
{
  "type": "sync.hello",
  "protocol": "sync/v1",
  "collections": [
    { "name": "devices", "cursor": 0 }   // 0 = "I have nothing, send full snapshot"
  ]
}
```

Server → client:

```jsonc
// Full state for a collection AS OF a captured head rev. Sent when cursor=0,
// when the client's cursor is below the DO's GC floor (§3.5), or on forced
// resync. The snapshot is rev-filtered: it contains ONLY records with
// rev <= snapshotRev (a record written after snapshotRev arrives as a normal
// delta, never inside the snapshot), so the snapshot is a consistent
// point-in-time view even though the underlying DO storage scan is not
// transactional.
{
  "type": "sync.snapshot",
  "collection": "devices",
  "snapshotRev": 184,         // captured collection head; becomes cursor on complete
  "records": [
    { "id": "dev-uuid-A", "rev": 181, "updatedAt": 1718312400000, "deleted": false,
      "payload": { /* DeviceRecord */ } },
    { "id": "dev-uuid-B", "rev": 184, "updatedAt": 1718312405000, "deleted": false,
      "payload": { /* DeviceRecord */ } }
  ],
  "complete": true            // false ⇒ more snapshot pages follow (paging, §3.4)
}

// Incremental change(s). Carries `rev` = the collection head this frame brings
// the client up to; `records` are every changed record in (cursor, rev]. Applied
// atomically; cursor advances to `rev` only after the whole frame commits (§3.1a).
{
  "type": "sync.delta",
  "collection": "devices",
  "rev": 185,                 // new cursor after this frame is fully applied
  "records": [
    { "id": "dev-uuid-A", "rev": 185, "updatedAt": 1718312410000, "deleted": false,
      "payload": { /* DeviceRecord */ } }
  ]
}

// Optional liveness/cursor heartbeat (lets a client persist its cursor even when
// nothing changed, and detect a silent stream). Cheap; piggybacks presence seen.
// `rev` is the current head; advancing the cursor to it on a tick is safe because
// the DO guarantees it has sent every record up to head (no skipped revs, §3.1a).
{ "type": "sync.tick", "collection": "devices", "rev": 185 }
```

Application rule on the client. A frame is applied **all-or-nothing in one local
SQLite transaction**; the cursor advances only on commit:

```
applyFrame(frame):                       // delta, tick, or one snapshot page-set
  begin transaction
    for r in frame.records:
      local = store.get(frame.collection, r.id)
      if local != nil and local.rev >= r.rev: continue        // stale/dup, ignore
      if r.deleted: store.tombstone(frame.collection, r.id, r.rev, r.updatedAt)
      else:         store.upsert(frame.collection, r.id, r.rev, r.updatedAt, r.payload)
    store.setCursor(frame.collection, to: frame.rev)           // monotone; == head
  commit                                  // a crash before commit re-pulls the frame
```

`store.setCursor` only moves forward (`max(current, frame.rev)`, but by
construction `frame.rev` is always `> current` for an in-order stream). A
`sync.snapshot` with `complete: true` commits `cursor = snapshotRev` and runs the
missing-record reconciliation (§3.2a). Deltas with `rev > snapshotRev` that arrive
during paging are NOT dropped; they are queued and applied after the snapshot
commits (§3.4), so a delete racing the snapshot is never lost.

### 3.2a Missing-record reconciliation (scoped to authoritative records only)

When a `complete: true` snapshot commits, the client removes any local record in
that collection with `1 <= rev <= snapshotRev` that was **not** present in the
snapshot. This catches a deletion whose tombstone the client missed while
disconnected: the record is simply absent from the fresh snapshot, so the client
drops it.

The `rev >= 1` lower bound is load-bearing: provisional migration rows (§6) carry
`rev = 0` and are therefore **exempt** from reconciliation. They are never deleted
by a snapshot and are only ever replaced by a real authoritative upsert
(`rev >= 1`) for the same id. Without this bound, the first snapshot would wipe
exactly the local fallback rows the migration promises to keep.

### 3.3 Connect handshake and the fast-start interplay

The launch path never waits on this. Sequence:

1. **t0 (launch):** UI reads the device collection straight from `CmuxSyncStore`
   (synchronous-feeling, single indexed SQLite query) and renders. No network.
2. **t0+ (background):** the sync client opens the WS. On connect it sends
   `sync.hello` with the persisted cursor for each subscribed collection.
3. The DO replies with a `sync.snapshot` if the cursor is `0`/stale, otherwise a
   `sync.delta` carrying only `rev > cursor` records (often empty).
4. The client applies records into SQLite and the `@Observable` store recomputes
   an immutable value-type snapshot array of devices, which it publishes; SwiftUI
   re-renders. Rows hold only value snapshots, never the store (§10a). The UI was
   never blank.
5. Steady state: `sync.delta` frames stream as the DO's collection changes.

If the WS is unreachable, the UI keeps showing the last-synced SQLite state
(correctly labeled by `updatedAt`/presence as possibly-stale) and retries with
backoff. This is the "instant and resilient" behavior requirement #2 asks for.

### 3.4 Paging large snapshots, and the snapshot/delta race

A collection snapshot can exceed a single WS frame budget. The snapshot is paged:
each page is a `sync.snapshot` with `complete: false` except the last, and all
pages share the same `snapshotRev` (the head captured at snapshot start). The
snapshot read is **rev-filtered**: the DO captures `snapshotRev = head` and emits
only records with `rev <= snapshotRev`. A record written after the capture (head
moves to `snapshotRev+1`) is never folded into a snapshot page; it goes out as a
normal `sync.delta`. This makes the snapshot a consistent point-in-time view even
though `storage.list` on the DO is not a transactional MVCC read.

The client buffers snapshot **pages** keyed by collection and commits (cursor +
reconciliation, §3.2a) only when the `complete: true` page arrives. Crucially,
`sync.delta` frames received **during** paging are not dropped: they are queued
in a separate per-collection delta queue, and after the snapshot commits the
client drains the queue (applying only records with `rev > snapshotRev`; any with
`rev <= snapshotRev` are already in the snapshot and the `local.rev >= r.rev`
guard ignores them). This is what closes the "delete races the snapshot" hole: a
device deleted mid-paging has its tombstone at `rev > snapshotRev`, so it is in
the queued deltas and removes the record right after the snapshot commits, never
leaving a ghost. If the stream drops mid-snapshot, the client discards both the
partial page buffer and the delta queue and re-hellos; nothing is committed
half-applied. For device-list (≤200 devices × small payloads) one page suffices,
but the protocol must not assume that for future collections (e.g. notifications).

### 3.5 Tombstones, deletion, GC, and the resync floor

A delete is a write: the DO sets `deleted: true`, bumps `rev`, writes a tombstone
record, and broadcasts a delta. Clients keep the tombstone (with its `rev`) so a
late-arriving older upsert for that id is ignored. Two durable bookkeeping keys
make GC and the horizon decision O(1) instead of a full scan:

- `synctomb:<collection>:<rev>` → recordId, an index of tombstones ordered by
  rev, so the alarm can find tombstones to GC by walking the oldest revs.
- `syncgcfloor:<collection>` → integer, the highest rev below which tombstones
  have been GC'd. Starts at 0.

The DO retains tombstones for a **deletion retention window** (default 7 days,
per collection). The alarm GC pass deletes tombstone records and their
`synctomb:` index entries older than the window, and raises `syncgcfloor` to the
highest GC'd tombstone rev. Note this window is independent of (and longer than)
the presence 24h offline tail: an offline device's last instance is *pruned* from
the presence map at 24h, which is the event that mints the device's sync
tombstone; that tombstone then lives its own 7 days for the sync horizon. So the
alarm carries two timers — the existing presence prune (24h) and the sync
tombstone GC (7 days) — scheduled via the same `nextAlarmTime` machinery extended
to consider `synctomb:` entries.

**The resync floor decides snapshot vs delta.** On `sync.hello` with
`cursor = C`: if `C >= syncgcfloor`, the DO can prove every deletion since `C` is
still represented by a retained tombstone, so it answers with deltas
(`rev > C`). If `C < syncgcfloor`, a deletion may have been GC'd that the client
never saw, so the DO cannot catch it up safely with deltas and forces a full
`sync.snapshot`; the client's reconciliation (§3.2a) then drops the missed
deletions. `cursor = 0` is always below the floor, so a first-time client always
gets a snapshot. This is the standard "snapshot if too far behind, else deltas"
design (Firebase/Replicache/CRDT-sync); the retention window is the only tunable.

### 3.6 Ordering and causality guarantees

- **Within a collection:** total order by `rev`, with the cursor as a
  contiguous-prefix watermark (§3.1a). Clients see a linearizable history.
- **Across collections:** no cross-collection ordering guarantee. Each
  collection has its own `rev` space and cursor. This is intentional: it keeps
  collections independent so adding one cannot perturb another, and no real cmux
  feature needs "device X changed strictly before workspace Y." If a future
  feature needs cross-collection atomicity, it models the related data as one
  collection (one record, one `rev`), not two.
- **Idempotency:** every apply is keyed on `(id, rev)` monotonicity and frames
  commit atomically, so retries, duplicates, and reconnect overlaps converge.

## 4. Local SQLite schema

One database, `cmux-sync.sqlite3`, opened exactly like
`MobilePairedMacStore.openConnection` (`sqlite3_open_v2`,
`SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`, WAL,
`foreign_keys = ON`). `PRAGMA user_version` drives lazy migrations on first
access, identical to the existing store.

### 4.1 Generic tables (collection-agnostic)

```sql
-- One row per synced record, across all collections. The payload is the
-- collection-typed JSON body, stored opaque; typed facades decode it.
CREATE TABLE sync_records (
  collection  TEXT    NOT NULL,
  record_id   TEXT    NOT NULL,
  rev         INTEGER NOT NULL,            -- per-(team,collection) logical clock
  updated_at  REAL    NOT NULL,            -- epoch SECONDS (wire updatedAt is ms; one
                                           -- documented /1000 boundary, mirrors
                                           -- MobilePairedMacStore's timeIntervalSince1970)
  sort_key    REAL    NOT NULL DEFAULT 0,  -- render order hint (e.g. lastSeenAt secs)
  deleted     INTEGER NOT NULL DEFAULT 0,  -- tombstone
  payload     TEXT    NOT NULL,            -- JSON; '{}' for tombstones
  team_id     TEXT    NOT NULL,            -- scope: never mix teams in one query
  PRIMARY KEY (team_id, collection, record_id)
);

-- Drives the launch query: filter live records of a collection, already in a
-- usable render order so Swift does minimal re-sorting. The launch read is
-- `WHERE team_id=? AND collection=? AND deleted=0 ORDER BY sort_key DESC`.
CREATE INDEX idx_sync_records_render
  ON sync_records (team_id, collection, deleted, sort_key);

-- One row per (team, collection): the client's durable cursor (contiguous-prefix
-- watermark, §3.1a) plus last-apply time for the staleness UI.
CREATE TABLE sync_cursors (
  team_id     TEXT    NOT NULL,
  collection  TEXT    NOT NULL,
  cursor_rev  INTEGER NOT NULL DEFAULT 0,
  synced_at   REAL    NOT NULL DEFAULT 0,  -- last successful apply, for staleness UI
  PRIMARY KEY (team_id, collection)
);
```

Unit boundary: the wire `updatedAt` and the `DeviceRecord.lastSeenAtAtRev` inside
the JSON payload are epoch **ms**; the `updated_at` and `sort_key` columns are
epoch **seconds** (the `MobilePairedMacStore` convention). The `/1000` conversion
happens at exactly one place (the store's upsert) and is covered by a test, so
the ms-in-payload / seconds-in-column split never drifts.

Team scoping is first-class in the key. The phone can hold cached data for
multiple teams without cross-contamination; reads always filter `team_id`. This
mirrors how `MobilePairedMacStore` scopes by `stack_user_id`, generalized.

### 4.2 Typed per-collection facade (device-list)

The device-list facade reads `sync_records WHERE collection='devices' AND
deleted=0` and decodes each `payload` into a `DeviceRecord`, producing the
existing two-level `RegistryDevice`/`RegistryAppInstance` shape the UI already
renders. No new UI model. The facade is the only code that knows the `devices`
payload schema; the store and transport stay generic. (The `deleted=0` filter is
load-bearing: tombstone rows store `payload = '{}'`, which would fail to decode a
`DeviceRecord`; the facade never touches them.)

```swift
public struct DeviceRecord: Codable, Equatable, Sendable {
    public var deviceId: String          // = sync record id
    public var platform: String
    public var displayName: String?
    public var ownerUserId: String       // owner pin, carried for display/trust
    public var lastSeenAtAtRev: Double    // epoch ms AS OF this rev; NOT live freshness
    public var instances: [InstanceRecord]
    public struct InstanceRecord: Codable, Equatable, Sendable {
        public var tag: String
        public var routes: [CmxAttachRoute]
        public var lastSeenAtAtRev: Double // epoch ms AS OF this rev
    }
}
```

What the synced record deliberately does and does NOT carry. The record carries
the **list-shape** fields: identity (deviceId, platform, displayName), owner,
routes, and the per-tag instance set. It does **not** carry live `online` or a
continuously-fresh `lastSeenAt`, because those change on every 15s heartbeat and
would churn `rev` (and the cursor) for no list-shape change (§5.2). The only
timestamp in the record is `lastSeenAtAtRev`, a stable as-of-this-rev value used
to seed "last seen ~N ago" when there is no live link.

This is the honest scope of requirement #1: the synced record collapses the
**durable list** (identity + routes + owner) onto the DO as a single source,
replacing the Aurora `GET /api/devices` fetch for that data. **Live
online/offline freshness still rides the existing presence event stream**
(`online`/`offline`/`seen`/`routes`), which flows unchanged on the same socket;
the UI overlays it onto the synced rows exactly as it overlays presence today.
So the list *membership and routes* are single-sourced from the DO; the *liveness
dot* remains a presence overlay. Trying to fold per-tick freshness into the
synced record would either freeze it stale or churn the cursor every 15s, so the
two-stream split (slow-changing synced records + fast presence ticks on one
socket) is the correct factoring, not a compromise.

## 5. DO changes: additive, schema-versioned, live-safe

This is the riskiest part because the DO is live. The design keeps the change
strictly additive so the existing presence path is untouched and the rollout
needs no data migration.

### 5.1 What the DO already has vs. what sync adds

The DO already stores, per team:

- `inst:<deviceId>:<tag>` → `PresenceInstance` (live map, 24h tail, self-healing)
- `owner:<deviceId>` → userId (durable owner pin)
- `meta:teamId`

Sync adds, per team, without touching any of the above:

- `synced:devices:<deviceId>` → `SyncRecord<DeviceRecord>` (the authoritative,
  rev-stamped device record the list reads; tombstones live here too with
  `deleted: true`).
- `synchead:devices` → integer (the per-collection `rev` logical clock). Read
  with a `?? 0` default; new code must never assume it exists, since old data has
  no such key.
- `synctomb:devices:<rev>` → deviceId (rev-ordered tombstone index for GC, §3.5).
- `syncgcfloor:devices` → integer (highest GC'd tombstone rev; the resync-floor
  watermark, §3.5; defaults to 0).
- A new class-migration tag is **not** needed: the DO class already uses
  `new_sqlite_classes = ["TeamPresence"]`; sync stores new keys in the same
  object's storage. Per `docs/presence-service.md` ("Class migrations do not
  touch the shape of data stored inside an object"), adding storage keys is a
  pure data-shape addition, not a class migration. No `wrangler.toml`
  `[[migrations]]` change, so no class-migration risk.

### 5.2 How device records are produced (derivation, not a second source)

The DO already receives everything it needs: identity, platform, displayName,
routes, owner (it pins it), and it computes online/offline in
`applyHeartbeat`/`expireInstances`. The sync layer is a **projection** of the
presence state machine. The derivation hook fires on **both** DO write paths,
because list-shape changes happen on both:

- **Heartbeat path (`heartbeat` → `applyHeartbeat`):** routes change, displayName
  change, a new `(deviceId, tag)` instance, an owner pin, or a goodbye that flips
  the last instance offline. After the existing presence write, the DO rebuilds
  that device's `DeviceRecord` from its instances + owner, compares it to the
  stored `synced:devices:<id>` payload, and if the list-shape changed, increments
  `synchead:devices`, stamps the new `rev`, writes the record, and broadcasts a
  `sync.delta`.
- **Alarm path (`alarm` → `expireInstances` / `shouldPrune`):** this is where
  offline transitions and removals actually happen, NOT the heartbeat path. A
  timeout flips an instance `online: true → false` (a list-shape-relevant change
  if it changes whether the device is rendered as reachable) — but since the
  synced record no longer carries `online` (§4.2), a pure online→offline flip is
  carried by the presence overlay and does **not** itself bump the sync `rev`. A
  `shouldPrune` that deletes a device's **last** instance (24h after it went
  offline) IS a list-membership change: the device leaves the list, so the DO
  writes a tombstone (`deleted: true`, new `rev`), writes the `synctomb:` index
  entry, and broadcasts the delta. So: timeout = presence-overlay event (no sync
  rev); prune of last instance = sync tombstone.

Crucially the existing presence events (`online`/`offline`/`routes`/`seen`)
continue to broadcast unchanged for any current consumer. Sync is an
**additional** broadcast on the same socket. A `seen` tick (pure liveness) and an
online↔offline flip do **not** bump the sync `rev`; only changes to list
membership, routes, identity, or owner mint a new `rev`. This keeps the cursor
quiet during steady-state heartbeating while the presence overlay still updates
the liveness dot in realtime.

### 5.3 Schema versioning and lazy upgrade of stored records

`SyncRecord` carries an explicit `schemaVersion` (default 1) in its stored shape.
The discipline from `docs/presence-service.md` applies directly:

- **Additive field** (new optional payload field): old records read fine with a
  default; no migration. This is the common case.
- **Breaking field change**: bump `schemaVersion`; on first touch (the next
  heartbeat that rebuilds that device's record, or a lazy upgrade in the
  constructor/alarm) the DO rewrites the record in the new shape and bumps `rev`
  so clients re-pull it. Because the sync records are *derived* from the live
  presence instances (which self-heal every 15s), a breaking change to the
  derived record shape costs almost nothing: within one heartbeat cycle every
  online device re-emits a fresh record. Offline-but-retained records are lazily
  upgraded on the alarm pass.

This is strictly easier than the owner-pin case the docs call out, because the
sync records are reconstructable from re-announcing hosts. The one durable thing
that is *not* reconstructable, the owner pin, is unchanged by this PR.

### 5.4 Cross-colo rollout tolerance

During a `wrangler deploy` rollout, old DO code (no sync keys) and new DO code
run in different colos until each instance is evicted and re-hydrated. New
clients that send `sync.hello` to an old instance get no `sync.snapshot` (the
old code ignores the unknown message type) and fall back to the registry (flag
behavior, §8). New instances serve sync immediately. No instance ever serves a
*corrupt* sync state because sync keys only exist where new code wrote them.
This is the additive-deploy property the presence docs require.

## 6. Transparent local→DO migration

Existing phones already have paired Macs in `paired-macs.sqlite3`
(`MobilePairedMacStore`). On sign-in (and on first launch after this ships),
these must transparently become DO device records with no UI and no user action,
idempotently.

Mechanism:

1. On sign-in, the migration runs once per (account, device-set) and is
   idempotent. It reads `MobilePairedMacStore.loadAll(stackUserID:)`.
2. For each paired Mac it does **not** write the DO directly (the phone is not
   the owner of a Mac's record; the Mac is). Instead it seeds the **local**
   `CmuxSyncStore` `devices` collection with a provisional record derived from
   the paired Mac (deviceId, displayName, routes, lastSeenAt, online=false,
   `rev = 0` provisional, `synced_at = 0` to mark it unconfirmed). This makes the
   new local-first list render instantly on the very first launch after upgrade,
   even before the first DO snapshot arrives, using data the phone already had.
3. When the DO snapshot/delta arrives, its authoritative records (with real
   `rev ≥ 1`) overwrite the provisional `rev = 0` rows by the normal apply rule
   (`r.rev > local.rev`). Provisional rows for devices the DO does not know about
   (e.g. a Mac that has not heartbeated since) remain as a best-effort fallback,
   exactly like today's paired-Mac fallback, until the DO confirms or the user
   forgets the device. This survives the first snapshot because the §3.2a
   reconciliation is scoped to `rev >= 1` and never deletes provisional `rev = 0`
   rows.
4. Idempotency key: a `migrated:<accountId>` marker row in `sync_cursors`
   (or a dedicated `sync_meta` row) records that seeding ran for this account, so
   re-running on the next sign-in is a no-op. Re-seeding is also naturally
   idempotent because provisional rows are keyed by deviceId and `rev = 0` never
   overwrites a real DO record.

The Mac's own records reach the DO through the Mac's existing presence
heartbeat, which already carries identity + routes. So the "real" migration of a
device into the DO is just the Mac continuing to heartbeat; the phone-side step
is purely seeding the local cache for instant first render. This keeps the phone
from ever forging a device it does not own (respecting the DO owner pin).

## 7. Conflict resolution: server-authoritative, justified

The DO is the single writer of the `devices` collection (it derives records from
heartbeats it alone processes). So for phase 1 there is **no client write to
conflict**, and the model is cleanly **server-authoritative**: the DO's `rev`
wins, always. Clients never mint `rev`s.

The general substrate must still pick a story for future collections that *do*
take client writes (e.g. settings, where the phone edits a value). The decision:

- **Default: server-authoritative with last-write-wins (LWW) at the DO.** A
  client write is a *request* (`sync.mutate`, see §10) carrying an idempotency
  key and the record's `payload`. The DO validates, applies LWW by its own
  receive order (it is the serialization point), assigns the next `rev`, and
  broadcasts. The client optimistically reflects its own mutation, then
  reconciles when the authoritative delta returns (its idempotency key lets it
  match its optimistic copy to the confirmed record). On conflict (two clients
  edit the same record) the DO's receive order decides; the loser sees the
  winner's value on the next delta. This is the Replicache/Linear-style
  "server-reconciled mutations" model. The client keeps a pre-mutation snapshot so
  a DO **rejection** (validation failure, not just a lost race) rolls the
  optimistic copy back, per the repo's optimistic-update rule; the §10 outbox
  stores both the mutation and its rollback snapshot.
- **Per-record, not per-field, by default.** Per-field merge (CRDT-ish) is more
  work and only pays off for genuinely concurrent multi-writer fields. cmux's
  near-term collections (devices, workspaces, settings) are single-logical-writer
  per record in practice (the Mac owns its device row; the user owns their
  settings; a workspace is owned by its host). A collection that genuinely needs
  field-level merge can opt into a per-field LWW merge rule via its
  `SyncCollection` descriptor (each field carries its own `rev`/timestamp) without
  changing the transport. The substrate supports it; nothing in phase 1 needs it.
- **Why not CRDTs (yet).** CRDTs buy conflict-free *concurrent multi-writer*
  convergence without a server arbiter. cmux already has a natural per-team
  serialization point (the DO) and a clear ownership model per record, so a CRDT
  would add payload overhead (vector clocks / tombstone sets), code complexity,
  and a harder mental model to solve a problem we do not have. The pragmatic
  lesson from Figma/Linear/Replicache writeups: use server-authoritative
  rev-based sync until you have a real concurrent-multi-writer-per-field
  requirement, then adopt CRDTs surgically for *that* collection. The substrate's
  per-collection merge rule is exactly the seam to do that later without a
  protocol rewrite.

## 8. The Aurora keep-vs-deprecate decision

**Decision: keep Aurora as a write-through durable backstop for phase 1, and
re-evaluate deprecating the read path only after the DO list is proven in
dogfood. Do not deprecate or migrate Aurora data in this PR.**

Rationale:

- Aurora is the only thing that survives a DO storage loss for *offline* devices.
  The DO presence tail is 24h and self-heals from heartbeats, but a device that
  has not heartbeated in days exists only in Aurora today. If we cut Aurora now
  and the DO loses storage (or a team's DO is migrated/reset), that long-tail
  device identity is gone. Aurora is the durable system of record; the DO is the
  realtime+fast-cache layer. Collapsing the *read path* (the list source) onto
  the DO is requirement #1 and is what this PR does; collapsing the *durable
  store* onto the DO is a separate, riskier step.
- Keeping Aurora also gives a clean fallback for the flag (§9): when
  `mobileDeviceListLocalFirst` is off or the DO is unreachable, the list falls
  back to `GET /api/devices` exactly as today. Zero regression risk for the
  Release build.
- The Mac's heartbeat already writes both Aurora (`POST /api/devices`) and the
  DO (presence heartbeat). That dual-write continues unchanged. So Aurora stays
  authoritative-durable and the DO stays the fast list source.

Divergence is real and bounded, not hand-waved. The DO-derived list and the
Aurora list are written on different paths/cadences, so the two list sources CAN
show a different device set: e.g. a device in Aurora that has not heartbeated to
the DO recently, or a DO device whose Aurora row lagged a write. The rule is
explicit: **when the flag is on and the DO is reachable, the DO list wins and
Aurora is not consulted; Aurora (then local paired Macs) is consulted only as a
fallback when the DO is unreachable or the local cache is empty** (§9). So a user
can see the fallback list briefly differ from the DO list across a
flag-flip/outage boundary. That is acceptable for phase 1 (the fallback is
strictly a degraded mode, clearly the older behavior), and it is the reason the
durable-store collapse is deferred to phase 2+ rather than done now: making the
DO the single durable store is what removes the divergence, and that is the step
that can lose long-tail data if rushed.

Phased Aurora plan (designed, not executed here):

- **Phase 1 (this PR):** Aurora intact; DO is the list source behind a flag with
  Aurora fallback. Dual-write continues.
- **Phase 2:** make the DO durably persist offline device records to its own
  SQLite-backed DO storage with a long retention (the DO already has SQLite
  storage via `new_sqlite_classes`). Verify the DO can serve the long tail.
- **Phase 3:** flip Release to local-first; keep Aurora as cold backup + the
  web/desktop registry consumer until those move to sync too.
- **Phase 4:** if/when web also reads from the DO, deprecate the Aurora read
  path; keep the table as an audit/export backstop or drop it after a data export.

This is the conservative call: requirement #1 (DO drives the list) is satisfied
now, and the durable-store migration is deferred behind dogfood evidence because
it is the part that can lose data if rushed.

## 9. Feature flag and rollout

Flag: `mobileDeviceListLocalFirst`, defined with the existing DEBUG-on/Release-off
pattern used by `PresenceServiceConfiguration` (the `#if DEBUG return true` seam),
overridable via env (`CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST`) and `UserDefaults`
(`mobileDeviceListLocalFirst`) so it can be toggled in dogfood without a rebuild.

Behavior matrix:

| Flag | DO reachable | List source |
|------|--------------|-------------|
| on   | yes          | `CmuxSyncStore` (instant) + live DO deltas. |
| on   | no           | `CmuxSyncStore` last-synced cache (labeled stale), retry DO. If cache empty, fall back to `GET /api/devices`, then local paired Macs. |
| off  | n/a          | Today's behavior exactly: `GET /api/devices` → `registryDevices`, presence overlay, paired-Mac fallback. |

Release ships with the flag off, so production users are unaffected until
dogfood approves flipping it. DEBUG builds (dogfood) get local-first by default.

## 10. The extensibility contract (how a future collection plugs in)

A new collection is one descriptor and one payload type. No transport change, no
store schema change, no new SQLite table.

```swift
public struct SyncCollection<Record: Codable & Sendable & Equatable>: Sendable {
    public let name: String                       // wire + storage key, e.g. "workspaces"
    public let schemaVersion: Int                 // for lazy record upgrades
    public let merge: @Sendable (_ incoming: SyncRecordEnvelope<Record>,
                                 _ local: SyncRecordEnvelope<Record>?) -> MergeOutcome
    // Default merge = server-authoritative LWW by rev. A collection only supplies
    // a custom merge to opt into per-field merge.
}
```

To add, say, a `workspaces` collection in a later phase:

1. Define `WorkspaceRecord: Codable`.
2. Register `SyncCollection(name: "workspaces", schemaVersion: 1, merge: .revWins)`
   in the client's collection registry and add `"workspaces"` to the
   `sync.hello` list.
3. On the DO side, register the same name and emit `sync.delta` from whatever DO
   write produces workspace changes (or a new DO if workspaces live elsewhere;
   the transport is per-team and collection-tagged, so multiple producers fan in).
4. Add a typed facade over `CmuxSyncStore` if the UI wants a typed view.

That is the whole cost. The collection gets: instant local render, snapshot+delta
sync, cursor-based catch-up, tombstones, team scoping, schema-versioned lazy
upgrade, and the flag-able rollout, for free. This is the property requirement #4
demands and the reason the device list is implemented as "a collection" rather
than bespoke device code.

Client write support (`sync.mutate`) is part of the contract but **not built in
phase 1** (device-list is read-only on the phone). Designed shape: a mutation is
`{ type: "sync.mutate", collection, id, idempotencyKey, payload }`; the client
records it in a local `sync_mutations` outbox table, applies it optimistically,
sends it, and on the confirming delta (matched by idempotency key) clears the
outbox row; on reconnect it replays unconfirmed outbox rows (idempotency key
dedupes server-side). This is the offline-write story, designed now, built when
the first writable collection lands.

## 10a. UI rendering discipline (the repo's SwiftUI hard rules)

The worktree CLAUDE.md has two load-bearing rules this design must honor, because
violating them reintroduces the issue-2586 100%-CPU spin:

- **Snapshot boundary for list subtrees.** The device list renders inside a
  `List`/`ForEach`. No view below that boundary may hold the `@Observable`
  `CmuxSyncStore` (no `@ObservedObject`, `@Bindable`, or a plain `let store`).
  The store recomputes an immutable `[RegistryDevice]` value array on each commit;
  rows receive immutable `DeviceRecord`/`RegistryDevice` values plus closure
  action bundles only. An orthogonal delta (one device changes) must not
  invalidate every row through a shared store reference. This follows the existing
  `IndexSectionActions`/`SectionGapActions` pattern.
- **No state mutation inside view-body computations.** Delta application writes
  SQLite and recomputes the published snapshot in a sync-client callback / reload
  path, never inside a `body` projection that feeds `ForEach`. The "new delta
  arrived → recompute list" work lives in the apply callback, not in the view.

The presence overlay (liveness dot) is applied the same value-snapshot way it is
today, so layering live presence onto synced rows does not cross the boundary.

## 11. Security

All existing presence security is preserved because sync rides the same
authenticated, team-scoped transport:

- **Team scope:** sync frames are served by the per-team DO derived from the
  *verified* team id (`idFromName(teamId)`), exactly like presence. A client can
  only ever subscribe to its own team's sync stream. `team_id` is in the local
  SQLite primary key so cached data cannot leak across teams on-device either.
- **Owner pins:** device records carry the DO's owner pin; a co-member cannot
  forge a device record because the DO only mints records from owner-validated
  heartbeats (the existing `checkDeviceOwner` guard). The phone-side seeding
  (§6) only writes the *local* cache, never the DO, so it cannot spoof ownership.
- **Same-account:** the local cache is scoped by team and effectively by account;
  account-switch races are guarded the same way `loadRegistryDevices` already
  guards (capture requesting user, discard stale results), and sign-out clears
  the synced collections for the signed-out scope.
- **Subscription deadlines:** sync inherits the existing token-expiry-capped
  stream deadline (`MAX_SUBSCRIBE_AGE_MS`); a revoked token cannot keep a sync
  stream alive any longer than it keeps presence alive.

## 12. Phase 1 scope vs. deferred

**Phase 1 ships (this PR):**

- Worker: additive sync layer in `workers/presence` — `SyncRecord`/`DeviceRecord`
  types, the per-collection `rev` head, device-record derivation on the heartbeat
  AND alarm paths, `sync.hello`/`sync.snapshot`/`sync.delta`/`sync.tick` over the
  existing WS, schemaVersion stamping, tombstones + `synctomb:` GC index +
  `syncgcfloor:` watermark. Bun tests for: durable record shape, schemaVersion
  lazy upgrade, delta cursor math (frame as atomic advance unit), snapshot
  rev-filtering + concurrent-delete-during-paging, gc-floor forced resync,
  tombstone GC, and derivation idempotency (a `seen` tick and an online↔offline
  flip do NOT bump rev; a routes/identity/membership change does).
- iOS: new `Packages/CmuxSyncStore` raw-SQLite3 package mirroring
  `MobilePairedMacStore` (actor, `CmuxSyncStoring` protocol, `CmuxSyncStoreError`
  enum, `PRAGMA user_version` migrations, generic `sync_records`/`sync_cursors`);
  a generic `SyncClient` that speaks `sync/v1` over the presence WS; a `devices`
  facade producing `RegistryDevice`s; device list rendered from the store on
  launch and live-updated by deltas, behind `mobileDeviceListLocalFirst`
  (DEBUG-on/Release-off) with registry + paired-Mac fallback when off/unreachable;
  transparent `MobilePairedMacStore`→local-seed migration on sign-in (idempotent).
- en+ja localization for any new user-facing strings (e.g. a "showing cached
  devices" staleness label, if added).

**Deferred (designed, not built):**

- Client writes / `sync.mutate` / outbox replay (no writable collection yet).
- Per-field CRDT merge (no concurrent-multi-writer field yet).
- Moving workspaces/settings/notifications onto sync (future registrations).
- DO durable long-tail device storage and the Aurora read-path deprecation
  (phases 2–4 in §8).
- Web/desktop reading the list from the DO (still on Aurora).

## 13. Residual risk

- **Changing a live DO.** Mitigated by making the change strictly additive (new
  storage keys, no class migration, presence path untouched) and tolerant of the
  cross-colo rollout window (old instances ignore `sync.hello`; clients fall back
  to the registry under the flag). The blast radius if sync is wrong is the
  DEBUG-only device list; Release is unaffected (flag off).
- **Cursor/horizon bugs** could cause a client to miss a tombstone and show a
  ghost device. The protocol closes the three known holes explicitly: the cursor
  is a contiguous-prefix watermark advanced per atomic frame (§3.1a), snapshots
  are `rev <= snapshotRev`-filtered with concurrent deltas queued and applied
  post-commit (§3.4), and a client below the GC floor is forced to a full
  snapshot + reconciliation (§3.5). Each is covered by a bun test (frame
  atomicity, snapshot-races-delete, gc-floor resync).
- **rev churn** from over-eager record derivation could spam deltas and burn the
  cursor. Mitigated by deriving records only on list-shape-relevant changes and
  asserting in tests that a pure `seen` tick does not bump `rev`.
- **Local cache staleness on a dead network** is shown to the user (labeled), not
  hidden; the design treats "instant but possibly stale, then live" as correct
  behavior, which is the whole point of local-first.
