// Storage-bound sync orchestration for the TeamPresence DO.
//
// This is the half of the sync layer that touches Durable Object storage. It is
// written against a minimal `SyncStorage` interface (the subset of
// `DurableObjectStorage` it needs) so it unit-tests against a Map-backed fake
// without the Workers runtime — the same testability posture as core.ts/sync.ts.
//
// Responsibilities (DESIGN.md §5):
//   - Own the per-collection key space inside the DO's storage, additive to the
//     existing presence keys (`inst:`/`owner:`/`meta:`), never touching them:
//       synced:<collection>:<id>   -> StoredSyncRecord (the authoritative record)
//       synchead:<collection>      -> number (the per-collection rev clock)
//       synctomb:<collection>:<rev>-> id (rev-ordered tombstone index for GC)
//       syncgcfloor:<collection>   -> number (highest GC'd tombstone rev)
//   - Mint a new rev ONLY when a record's list-shape actually changes, so a
//     steady-state heartbeat (`seen` tick / online↔offline flip) does not churn
//     the cursor (DESIGN.md §5.2). The caller passes already-derived records;
//     this layer decides write-or-skip by comparing the stored payload.
//   - Build rev-filtered snapshots (records with rev <= snapshotRev) and deltas
//     (records with rev > cursor) and decide snapshot-vs-delta from the GC floor.
//   - GC tombstones past the retention window and raise the GC floor.
//   - Lazily upgrade stored records whose schemaVersion is below current.
//
// Every key read uses `?? default` so this code runs correctly against an old
// DO instance that has never written a sync key (the additive-rollout property
// in DESIGN.md §5.4). It never assumes a sync key exists.

import {
  buildDelta,
  makeRecord,
  makeTombstone,
  pageSnapshot,
  resolveHello,
  shouldGcTombstone,
  SYNC_SCHEMA_VERSION,
  TOMBSTONE_RETENTION_MS,
  type SyncDeltaFrame,
  type SyncRecord,
  type SyncSnapshotFrame,
} from "./sync";

/** The subset of `DurableObjectStorage` the sync layer uses. A Map-backed fake
 * implements this for unit tests; the real DO passes `ctx.storage`. */
export interface SyncStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  /** Atomic multi-key write. `DurableObjectStorage.put(entries)` commits all
   * keys in one transaction, so the record + head (+ tombstone index) cannot be
   * left half-written with a record rev above the head. */
  put(entries: Record<string, unknown>): Promise<void>;
  delete(key: string): Promise<boolean>;
  list<T>(options: { prefix: string; limit?: number }): Promise<Map<string, T>>;
}

/** A record as stored durably. Identical to the wire `SyncRecord` — the stored
 * shape and the wire shape are the same object, which keeps the snapshot/delta
 * build a straight pass-through and makes schemaVersion the only thing the
 * lazy-upgrade pass touches. */
export type StoredSyncRecord<P = unknown> = SyncRecord<P>;

const RECORD_PREFIX = "synced:";
const HEAD_PREFIX = "synchead:";
const TOMB_PREFIX = "synctomb:";
const GC_FLOOR_PREFIX = "syncgcfloor:";
/** `syncbackfill:<collection>` -> 1, set once the DO has projected its full
 * pre-existing presence map into the collection on rollout. Distinct from
 * head !== 0: a head can become nonzero from a single device's change while
 * other devices that only `seen`-heartbeat were never projected, so head is NOT
 * proof the projection is complete (DESIGN.md §5.4 rollout). */
const BACKFILL_PREFIX = "syncbackfill:";
/** `syncepoch:<collection>` -> the collection-history generation. Minted once
 * (lazily) the first time the DO writes the collection; a fresh DO (reset/
 * rollback) re-mints a different value, so a client carrying the old epoch
 * detects the reset even when the new head coincidentally equals its cached one
 * (the equal-head aliasing hole, DESIGN.md §3.6). */
const EPOCH_PREFIX = "syncepoch:";

function recordKey(collection: string, id: string): string {
  return `${RECORD_PREFIX}${collection}:${id}`;
}
function recordPrefix(collection: string): string {
  return `${RECORD_PREFIX}${collection}:`;
}
function headKey(collection: string): string {
  return `${HEAD_PREFIX}${collection}`;
}
/** Tombstone index key. The rev is zero-padded so a lexical `list` over the
 * prefix returns tombstones in rev order, which is what the GC walk relies on
 * to find the oldest tombstones first without sorting. 16 digits covers any
 * rev a single team will ever mint. */
function tombKey(collection: string, rev: number): string {
  return `${TOMB_PREFIX}${collection}:${String(rev).padStart(16, "0")}`;
}
function tombPrefix(collection: string): string {
  return `${TOMB_PREFIX}${collection}:`;
}
function gcFloorKey(collection: string): string {
  return `${GC_FLOOR_PREFIX}${collection}`;
}
function backfillKey(collection: string): string {
  return `${BACKFILL_PREFIX}${collection}`;
}
function epochKey(collection: string): string {
  return `${EPOCH_PREFIX}${collection}`;
}

/** Read the collection-history epoch, minting and persisting one on first read
 * if absent. The epoch is `nowMs` at first mint: monotone and effectively unique
 * per DO-storage lifetime, so a reset re-mints a strictly different value. */
export async function readOrMintEpoch(
  storage: SyncStorage,
  collection: string,
  nowMs: number,
): Promise<number> {
  const existing = await storage.get<number>(epochKey(collection));
  if (existing !== undefined && existing > 0) return existing;
  const minted = nowMs;
  await storage.put(epochKey(collection), minted);
  return minted;
}

/** Read the epoch without minting (0 if none yet). */
export async function readEpoch(storage: SyncStorage, collection: string): Promise<number> {
  return (await storage.get<number>(epochKey(collection))) ?? 0;
}

/** Whether the one-time rollout backfill (project the full pre-existing presence
 * map into the collection) has run. Defaults false on an old DO. */
export async function readBackfillDone(storage: SyncStorage, collection: string): Promise<boolean> {
  return ((await storage.get<number>(backfillKey(collection))) ?? 0) === 1;
}

/** Mark the one-time rollout backfill complete. */
export async function markBackfillDone(storage: SyncStorage, collection: string): Promise<void> {
  await storage.put(backfillKey(collection), 1);
}

/** Read the per-collection rev clock, defaulting to 0 for a collection (or an
 * old DO instance) that has never been written. */
export async function readHead(storage: SyncStorage, collection: string): Promise<number> {
  return (await storage.get<number>(headKey(collection))) ?? 0;
}

/** Read the GC floor (highest GC'd tombstone rev), defaulting to 0. */
export async function readGcFloor(storage: SyncStorage, collection: string): Promise<number> {
  return (await storage.get<number>(gcFloorKey(collection))) ?? 0;
}

/** Read all stored records for a collection (live + tombstones). */
export async function listRecords<P>(
  storage: SyncStorage,
  collection: string,
): Promise<StoredSyncRecord<P>[]> {
  const map = await storage.list<StoredSyncRecord<P>>({ prefix: recordPrefix(collection) });
  return [...map.values()];
}

/** Read one stored record, or undefined. */
export async function readRecord<P>(
  storage: SyncStorage,
  collection: string,
  id: string,
): Promise<StoredSyncRecord<P> | undefined> {
  return await storage.get<StoredSyncRecord<P>>(recordKey(collection, id));
}

/** Result of a write attempt: the frame to broadcast, or null when nothing
 * changed (so the caller broadcasts nothing and the cursor stays put). */
export interface SyncWriteResult<P> {
  /** The delta frame to broadcast, or null if the write was a no-op. */
  delta: SyncDeltaFrame<P> | null;
  /** The new collection head after this write (unchanged if no-op). */
  head: number;
}

/** Upsert a derived record if its payload differs from what is stored. Mints a
 * new rev and writes a delta only on a real change; an identical payload is a
 * no-op that does not touch the head or the cursor (DESIGN.md §5.2).
 *
 * `shapeEqual(a, b)` decides "same list-shape" for the collection (device-list
 * passes `deviceShapeChanged`-derived equality); when omitted, a structural
 * JSON compare is used. The caller has already derived `payload`. */
export async function upsertRecord<P>(
  storage: SyncStorage,
  collection: string,
  id: string,
  payload: P,
  nowMs: number,
  shapeEqual: (stored: P, next: P) => boolean = defaultPayloadEqual,
  freshnessOf?: (payload: P) => number,
): Promise<SyncWriteResult<P>> {
  const head = await readHead(storage, collection);
  const stored = await readRecord<P>(storage, collection, id);
  if (stored !== undefined && !stored.deleted && shapeEqual(stored.payload, payload)) {
    // No list-shape change: keep the rev, do not broadcast. This is what keeps
    // the cursor quiet through steady-state heartbeats. Optionally refresh
    // freshness metadata (e.g. `lastSeenAt`) IN PLACE — same rev, no delta — so a
    // consumer that orders/LWW-merges by it (the iOS paired-Mac restore) sees a
    // republish of the same live shape as fresh, instead of skipping the backup
    // and keeping a stale local route.
    if (freshnessOf && freshnessOf(payload) > freshnessOf(stored.payload)) {
      const refreshed: StoredSyncRecord<P> = { ...stored, payload, updatedAt: nowMs };
      await storage.put({ [recordKey(collection, id)]: refreshed });
    }
    return { delta: null, head };
  }
  const rev = head + 1;
  const record = makeRecord(id, rev, nowMs, payload);
  // Atomic: record + head (+ epoch on the very first write) commit together, so
  // storage can never hold a record whose rev exceeds the head, and the epoch
  // exists as soon as the collection has any state — even after a reset rebuilds
  // to the same head, so equal-head reset detection is never disabled by a
  // missing server epoch (DESIGN.md §3.6).
  await storage.put({
    [recordKey(collection, id)]: record,
    [headKey(collection)]: rev,
    ...(await firstWriteEpochEntry(storage, collection, head, nowMs)),
  });
  return { delta: buildDelta(collection, rev, [record]), head: rev };
}

/** On the FIRST write to a collection (prior head 0), mint and include the epoch
 * key so it is created atomically with the head. On a reset the wiped storage
 * starts at head 0 again, so the rebuild mints a fresh epoch a stale client will
 * mismatch. Subsequent writes (head > 0) leave the existing epoch untouched. */
async function firstWriteEpochEntry(
  storage: SyncStorage,
  collection: string,
  priorHead: number,
  nowMs: number,
): Promise<Record<string, number>> {
  if (priorHead > 0) return {};
  // Defensive: if an epoch somehow already exists (e.g. minted by a hello before
  // the first write), keep it rather than overwriting.
  const existing = await readEpoch(storage, collection);
  if (existing > 0) return {};
  return { [epochKey(collection)]: nowMs };
}

/** Tombstone a record (the device left the list). Mints a new rev, writes the
 * tombstone record, adds the rev-ordered `synctomb:` index entry for GC, and
 * returns the delta. A no-op if the record is already a tombstone (idempotent on
 * a double prune). */
export async function tombstoneRecord(
  storage: SyncStorage,
  collection: string,
  id: string,
  nowMs: number,
): Promise<SyncWriteResult<Record<string, never>>> {
  const head = await readHead(storage, collection);
  const stored = await readRecord(storage, collection, id);
  if (stored === undefined || stored.deleted) {
    // Nothing to delete, or already a tombstone: idempotent no-op.
    return { delta: null, head };
  }
  const rev = head + 1;
  const tomb = makeTombstone(id, rev, nowMs);
  // Atomic: tombstone record + head + rev-ordered GC index commit together, so
  // the GC index can never reference a head that does not include the tombstone.
  await storage.put({
    [recordKey(collection, id)]: tomb,
    [headKey(collection)]: rev,
    [tombKey(collection, rev)]: id,
  });
  return { delta: buildDelta(collection, rev, [tomb]), head: rev };
}

/** Lazily upgrade a stored record whose schemaVersion is below current. The
 * `upgrade` callback rewrites the payload into the new shape; the record is
 * re-stamped at a NEW rev so clients re-pull it (DESIGN.md §5.3). Returns the
 * delta to broadcast, or null when the record is already current. Tombstones are
 * never upgraded (their payload is `{}`). */
export async function lazyUpgradeRecord<P>(
  storage: SyncStorage,
  collection: string,
  id: string,
  nowMs: number,
  upgrade: (payload: P, fromVersion: number) => P,
): Promise<SyncWriteResult<P>> {
  const head = await readHead(storage, collection);
  const stored = await readRecord<P>(storage, collection, id);
  if (stored === undefined || stored.deleted || stored.schemaVersion >= SYNC_SCHEMA_VERSION) {
    return { delta: null, head };
  }
  const upgraded = upgrade(stored.payload, stored.schemaVersion);
  const rev = head + 1;
  const record = makeRecord(id, rev, nowMs, upgraded);
  await storage.put({ [recordKey(collection, id)]: record, [headKey(collection)]: rev });
  return { delta: buildDelta(collection, rev, [record]), head: rev };
}

/** Build the snapshot pages for a hello whose cursor forces a full snapshot.
 * Rev-filtered to `rev <= snapshotRev` so the snapshot is a consistent
 * point-in-time view even though `list` is not transactional (DESIGN.md §3.4).
 * Tombstones inside the window are included so a client reconciliation can drop
 * a record it has but the live set does not — but already-current live records
 * dominate; the client's `local.rev >= r.rev` guard ignores stale ones. */
export async function buildSnapshotPages<P>(
  storage: SyncStorage,
  collection: string,
  pageSize?: number,
  nowMs: number = Date.now(),
): Promise<{ snapshotRev: number; epoch: number; pages: SyncSnapshotFrame<P>[] }> {
  const snapshotRev = await readHead(storage, collection);
  const epoch = await readOrMintEpoch(storage, collection, nowMs);
  const all = await listRecords<P>(storage, collection);
  const filtered = all
    .filter((r) => r.rev <= snapshotRev)
    .sort((a, b) => a.rev - b.rev);
  return { snapshotRev, epoch, pages: pageSnapshot(collection, snapshotRev, filtered, pageSize, epoch) };
}

/** Build the delta records to catch a client up from `sinceRev` to head: every
 * stored record (live or tombstone) with `rev > sinceRev`, in rev order, and the
 * head they advance the cursor to. Returns null records when already current. */
export async function buildCatchupDelta<P>(
  storage: SyncStorage,
  collection: string,
  sinceRev: number,
): Promise<SyncDeltaFrame<P> | null> {
  const head = await readHead(storage, collection);
  if (head <= sinceRev) return null;
  const all = await listRecords<P>(storage, collection);
  const records = all
    .filter((r) => r.rev > sinceRev)
    .sort((a, b) => a.rev - b.rev);
  return buildDelta(collection, head, records);
}

/** Answer one collection in a `sync.hello`: decide snapshot vs delta from the GC
 * floor (DESIGN.md §3.5), then build the frames. A cursor below the floor (or 0
 * with any GC having happened) forces a full snapshot + client reconciliation. */
export async function resolveHelloFrames<P>(
  storage: SyncStorage,
  collection: string,
  cursor: number,
  pageSize?: number,
  clientEpoch = 0,
  nowMs: number = Date.now(),
): Promise<
  | { mode: "snapshot"; snapshotRev: number; epoch: number; pages: SyncSnapshotFrame<P>[] }
  | { mode: "delta"; delta: SyncDeltaFrame<P> | null }
> {
  const gcFloor = await readGcFloor(storage, collection);
  const head = await readHead(storage, collection);
  // Ensure an epoch exists whenever the collection has state, so the
  // equal-head reset guard is never disabled by a missing epoch — including for
  // pre-epoch records written before this code shipped (head > 0, epoch 0). On a
  // truly empty collection (head 0) cursor-0/snapshot handling already covers it.
  const serverEpoch = head > 0
    ? await readOrMintEpoch(storage, collection, nowMs)
    : await readEpoch(storage, collection);
  const resolution = resolveHello({ cursor, gcFloor, head, clientEpoch, serverEpoch });
  if (resolution.mode === "snapshot") {
    const { snapshotRev, epoch, pages } = await buildSnapshotPages<P>(storage, collection, pageSize, nowMs);
    return { mode: "snapshot", snapshotRev, epoch, pages };
  }
  const delta = await buildCatchupDelta<P>(storage, collection, resolution.sinceRev);
  return { mode: "delta", delta };
}

/** GC tombstones past the retention window. Walks the rev-ordered `synctomb:`
 * index oldest-first, deletes each expired tombstone record and its index
 * entry, and raises the GC floor to the highest GC'd rev. O(expired), not a full
 * scan. Returns the number GC'd and the new floor. */
/** Distinct collections that currently hold tombstone index entries under a base
 * prefix — e.g. base `"pairedMacs:"` returns every `pairedMacs:<userId>`
 * collection with a tombstone. Lets the alarm GC per-user collections it does not
 * know by name. Tombstone keys are `synctomb:<collection>:<16-digit rev>`, so the
 * collection is the key minus the `synctomb:` prefix and the trailing `:<rev>`. */
export async function listTombstonedCollections(
  storage: SyncStorage,
  basePrefix: string,
): Promise<string[]> {
  const index = await storage.list<string>({ prefix: `${TOMB_PREFIX}${basePrefix}` });
  const collections = new Set<string>();
  for (const indexKey of index.keys()) {
    const body = indexKey.slice(TOMB_PREFIX.length);
    const lastColon = body.lastIndexOf(":");
    if (lastColon > 0) collections.add(body.slice(0, lastColon));
  }
  return [...collections];
}

export async function gcTombstones(
  storage: SyncStorage,
  collection: string,
  nowMs: number,
  retentionMs: number = TOMBSTONE_RETENTION_MS,
): Promise<{ collected: number; floor: number }> {
  const index = await storage.list<string>({ prefix: tombPrefix(collection) });
  // `list` returns keys in lexical order; the padded rev makes that rev order.
  const startFloor = await readGcFloor(storage, collection);

  // Pass 1: decide what to remove WITHOUT mutating yet. Separate the stale index
  // entries (record came back to life) from the real tombstones to GC, and
  // compute the floor we would advance to.
  const staleIndexKeys: string[] = [];
  const toGc: { indexKey: string; id: string; rev: number }[] = [];
  let floor = startFloor;
  for (const [indexKey, id] of index) {
    const record = await readRecord(storage, collection, id);
    if (record !== undefined && !record.deleted) {
      // The device came back; the index entry is stale (the live record is not a
      // tombstone). Drop only the index entry, never the live record.
      staleIndexKeys.push(indexKey);
      continue;
    }
    if (record !== undefined && !shouldGcTombstone(record, nowMs, retentionMs)) {
      // Index is rev-ordered, but retention is time-ordered; a newer tombstone
      // can be older in wall-clock if clocks jump. Keep scanning rather than
      // breaking so we never strand an expired entry behind a fresh one.
      continue;
    }
    const rev = revFromTombKey(indexKey, collection);
    toGc.push({ indexKey, id, rev });
    if (rev > floor) floor = rev;
  }

  // Crash-safety: raise the floor FIRST, before deleting any tombstone (and in
  // the same atomic write). If the alarm is interrupted after this point but
  // before the deletes, the tombstones simply linger and are re-GC'd next pass
  // (idempotent), while the floor already (conservatively) forces a client whose
  // cursor predates a GC'd deletion onto a full snapshot — so a missed delete
  // can never be silently lost (DESIGN.md §3.5). Deleting first and raising the
  // floor last would lose the delete on a crash in between.
  if (floor > startFloor) {
    await storage.put(gcFloorKey(collection), floor);
  }
  for (const { indexKey, id } of toGc) {
    await storage.delete(recordKey(collection, id));
    await storage.delete(indexKey);
  }
  for (const indexKey of staleIndexKeys) {
    await storage.delete(indexKey);
  }
  return { collected: toGc.length, floor };
}

/** The epoch ms at which the OLDEST retained tombstone in a collection becomes
 * GC-eligible, or null when there are no tombstones. The alarm includes this in
 * its next-fire calculation so a team that has gone fully offline (no instances
 * left to schedule a heartbeat-driven alarm) still wakes to GC its tombstones
 * and advance the GC floor (DESIGN.md §3.5). O(tombstones) but tombstones are
 * few and short-lived; only the min matters. */
export async function nextTombstoneGcTime(
  storage: SyncStorage,
  collection: string,
  retentionMs: number = TOMBSTONE_RETENTION_MS,
): Promise<number | null> {
  const index = await storage.list<string>({ prefix: tombPrefix(collection) });
  let earliest: number | null = null;
  for (const id of index.values()) {
    const record = await readRecord(storage, collection, id);
    if (record === undefined || !record.deleted) continue;
    const due = record.updatedAt + retentionMs;
    if (earliest === null || due < earliest) earliest = due;
  }
  return earliest;
}

function revFromTombKey(key: string, collection: string): number {
  const padded = key.slice(tombPrefix(collection).length);
  const rev = Number(padded);
  return Number.isFinite(rev) ? rev : 0;
}

/** Default payload equality: a structural JSON compare. Collections that need a
 * shape-aware compare (e.g. device-list, which ignores per-tick timestamps)
 * pass their own to `upsertRecord`. */
function defaultPayloadEqual<P>(a: P, b: P): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}
