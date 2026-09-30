// Generic local-first sync substrate (sync/v1) — pure layer.
//
// This is the cloud half of the cmux local-first sync protocol designed in
// plans/feat-do-device-list/DESIGN.md. It is collection-agnostic: a record is
// an opaque, collection-tagged payload stamped with a per-(team, collection)
// monotone `rev` (a logical clock), an `updatedAt`, and a tombstone flag.
//
// Everything here is pure and synchronous so it unit-tests without the Workers
// runtime or Durable Object storage, exactly like core.ts. The DO (do.ts) wires
// these functions to storage and the WebSocket broadcast; the device-list
// projection lives in syncDevices.ts.
//
// The protocol invariants this module enforces (see DESIGN.md §3):
//   - `rev` is a per-collection logical clock; records are stamped in write
//     order, so a cursor "send everything with rev > cursor" is a true
//     contiguous-prefix watermark, not a high-water mark with holes.
//   - A delta/snapshot frame carries the head `rev` it advances the client to;
//     the client commits the whole frame atomically and only then advances its
//     cursor. This module produces well-formed frames; the client (Swift) does
//     the atomic apply.
//   - Snapshots are rev-filtered (`rev <= snapshotRev`) so a snapshot is a
//     consistent point-in-time view even though DO storage scans are not
//     transactional; records written after the capture flow as normal deltas.
//   - Tombstones are retained for a deletion window; a GC floor watermark lets a
//     too-far-behind client be forced to a full snapshot.

/** Current sync wire/record schema version. Stored on each record so a breaking
 * payload-shape change can be detected and lazily upgraded on first touch
 * (DESIGN.md §5.3). Additive payload fields do NOT bump this. */
export const SYNC_SCHEMA_VERSION = 1;

export const SYNC_PROTOCOL = "sync/v1";

/** How long a tombstone is retained before GC. After this, a client whose
 * cursor predates the GC'd tombstone can no longer be caught up with deltas and
 * is forced to a full snapshot (see `resolveHello`). Independent of and longer
 * than the presence 24h offline tail (DESIGN.md §3.5). */
export const TOMBSTONE_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

/** Max records per snapshot page. Snapshots beyond this are paged; the client
 * commits only on the `complete: true` page (DESIGN.md §3.4). Device-list fits
 * in one page, but the protocol must page for future large collections. */
export const SNAPSHOT_PAGE_SIZE = 200;

/** One synced record as stored and as it appears on the wire. The `payload` is
 * opaque to this layer; collection facades own its schema. */
export interface SyncRecord<P = unknown> {
  /** Stable record id, unique within (team, collection). */
  id: string;
  /** Per-(team, collection) logical clock value stamped at write time. */
  rev: number;
  /** Epoch ms the DO last wrote this record. Tiebreak/debug only; `rev` orders. */
  updatedAt: number;
  /** Tombstone: a deleted record keeps its rev so a late older upsert is
   * ignored and the client can drop it. */
  deleted: boolean;
  /** Schema version of `payload`'s shape (DESIGN.md §5.3). */
  schemaVersion: number;
  /** Collection-typed body. `{}` for tombstones. */
  payload: P;
}

/** Client → server: subscribe to collections with the cursors I already hold.
 * `epoch` is the collection-history generation the client last synced against
 * (0/absent for a first-time client). A mismatch with the server's epoch means
 * the DO storage was reset/rolled back since the client synced, so the server
 * forces a snapshot even when the cursor looks current (DESIGN.md §3.6). */
export interface SyncHello {
  type: "sync.hello";
  protocol: string;
  collections: { name: string; cursor: number; epoch?: number }[];
}

/** Server → client: full state of a collection as of `snapshotRev`. Paged. */
export interface SyncSnapshotFrame<P = unknown> {
  type: "sync.snapshot";
  collection: string;
  /** Captured collection head; becomes the cursor when `complete` is true. */
  snapshotRev: number;
  /** The collection-history generation this snapshot belongs to. The client
   * stores it; a snapshot whose epoch differs from the client's stored epoch is
   * a reset and is applied authoritatively (clear + reconcile), which closes the
   * equal-head-after-reset aliasing hole (DESIGN.md §3.6). */
  epoch: number;
  records: SyncRecord<P>[];
  /** false ⇒ more pages follow; the client commits only on the complete page. */
  complete: boolean;
}

/** Server → client: incremental change(s). `rev` is the head this frame brings
 * the client up to; `records` are the changed records in (cursor, rev]. */
export interface SyncDeltaFrame<P = unknown> {
  type: "sync.delta";
  collection: string;
  rev: number;
  records: SyncRecord<P>[];
}

/** Server → client: liveness + cursor tick when nothing record-shaped changed. */
export interface SyncTickFrame {
  type: "sync.tick";
  collection: string;
  rev: number;
}

export type SyncServerFrame<P = unknown> =
  | SyncSnapshotFrame<P>
  | SyncDeltaFrame<P>
  | SyncTickFrame;

/** Parse a `sync.hello` from an already-JSON-decoded WS message, or null if it
 * is not a well-formed hello (the DO ignores unknown messages, so a non-hello
 * is simply not handled). Bounds the collection list defensively. Pure. */
export function parseHello(body: unknown, maxCollections = 32): SyncHello | null {
  if (body === null || typeof body !== "object") return null;
  const obj = body as Record<string, unknown>;
  if (obj.type !== "sync.hello") return null;
  if (typeof obj.protocol !== "string") return null;
  if (!Array.isArray(obj.collections)) return null;
  const collections: { name: string; cursor: number; epoch?: number }[] = [];
  // Dedup by collection name, keeping the FIRST occurrence: a hello that repeats
  // the same collection N times must not amplify into N backfill checks + N
  // snapshot/delta serializations downstream. The DO's per-connection guard
  // already dedups across separate hellos; this closes the within-one-hello gap
  // at the parse boundary too (defense in depth, and keeps the pure parser the
  // single source of the dedup invariant).
  const seen = new Set<string>();
  for (const entry of obj.collections.slice(0, maxCollections)) {
    if (entry === null || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === "string" ? e.name.trim() : "";
    if (name === "") continue;
    if (seen.has(name)) continue;
    seen.add(name);
    const cursor = Number(e.cursor);
    const epoch = Number(e.epoch);
    collections.push({
      name,
      cursor: Number.isFinite(cursor) && cursor >= 0 ? Math.floor(cursor) : 0,
      epoch: Number.isFinite(epoch) && epoch >= 0 ? Math.floor(epoch) : 0,
    });
  }
  return { type: "sync.hello", protocol: obj.protocol, collections };
}

export type HelloResolution =
  /** Cursor is recent enough: catch up with deltas (rev > cursor). */
  | { mode: "delta"; sinceRev: number }
  /** Cursor predates the GC floor (or is 0): send a full snapshot. */
  | { mode: "snapshot" };

/** Decide how to answer a hello for one collection, given the client's cursor,
 * the GC floor (highest GC'd tombstone rev), and the current head.
 *
 * - cursor >= head: already current; nothing to send beyond an optional tick.
 * - cursor >= gcFloor and cursor < head: every deletion since the cursor is
 *   still represented by a retained tombstone, so deltas are safe.
 * - cursor < gcFloor (always true for cursor 0): a deletion may have been GC'd
 *   that the client never saw; deltas cannot prove it, so force a snapshot.
 *
 * Pure for tests (DESIGN.md §3.5). */
export function resolveHello(input: {
  cursor: number;
  gcFloor: number;
  head: number;
  /** Generation the client last synced against (0 if first-time/unknown). */
  clientEpoch?: number;
  /** The DO's current collection-history generation. */
  serverEpoch?: number;
}): HelloResolution {
  // Epoch mismatch = the DO history was reset/rolled back since the client
  // synced. Force a snapshot even if the cursor looks current, which closes the
  // equal-head-after-reset aliasing hole (a new history coincidentally at the
  // same head as the client's cached old history). A client epoch of 0 (first
  // time, or pre-epoch client) only forces a snapshot when the server has a
  // nonzero epoch it could not have matched. (DESIGN.md §3.6)
  if (
    input.serverEpoch !== undefined &&
    input.serverEpoch !== 0 &&
    (input.clientEpoch ?? 0) !== input.serverEpoch
  ) {
    return { mode: "snapshot" };
  }
  // A first-time client (cursor 0) always gets a snapshot: it has nothing, so it
  // needs the paged full state and the snapshot reconciliation, not a catch-up
  // delta (DESIGN.md §3.5 "cursor = 0 ... always gets a snapshot").
  if (input.cursor <= 0) return { mode: "snapshot" };
  // A cursor below the GC floor may have missed a GC'd deletion: full snapshot.
  if (input.cursor < input.gcFloor) return { mode: "snapshot" };
  // A cursor AHEAD of the head cannot have come from this DO's current history
  // (storage was reset/rolled back, or the client cached a previous history).
  // Delta mode would send nothing (head <= cursor), leaving stale/deleted
  // devices forever. Force a snapshot so the client reconciles to current state.
  if (input.cursor > input.head) return { mode: "snapshot" };
  return { mode: "delta", sinceRev: input.cursor };
}

/** Page a record set into snapshot frames sharing one `snapshotRev`. The last
 * page is `complete: true`; an empty collection still yields one empty complete
 * page so the client commits its cursor and runs reconciliation. The caller is
 * responsible for passing only `rev <= snapshotRev` records (rev-filtered read).
 * Pure for tests (DESIGN.md §3.4). */
export function pageSnapshot<P>(
  collection: string,
  snapshotRev: number,
  records: readonly SyncRecord<P>[],
  pageSize = SNAPSHOT_PAGE_SIZE,
  epoch = 0,
): SyncSnapshotFrame<P>[] {
  const pages: SyncSnapshotFrame<P>[] = [];
  const size = Math.max(1, pageSize);
  for (let i = 0; i < records.length; i += size) {
    const slice = records.slice(i, i + size);
    pages.push({
      type: "sync.snapshot",
      collection,
      snapshotRev,
      epoch,
      records: slice,
      complete: i + size >= records.length,
    });
  }
  if (pages.length === 0) {
    pages.push({
      type: "sync.snapshot",
      collection,
      snapshotRev,
      epoch,
      records: [],
      complete: true,
    });
  }
  return pages;
}

/** Build a delta frame from the records a single write changed. `rev` is the
 * new head the frame advances the client to (the max stamped rev). Pure. */
export function buildDelta<P>(
  collection: string,
  head: number,
  records: readonly SyncRecord<P>[],
): SyncDeltaFrame<P> {
  return { type: "sync.delta", collection, rev: head, records: [...records] };
}

/** Whether a stored tombstone is old enough to GC, given its updatedAt and the
 * retention window. Pure. */
export function shouldGcTombstone(
  record: Pick<SyncRecord, "deleted" | "updatedAt">,
  nowMs: number,
  retentionMs = TOMBSTONE_RETENTION_MS,
): boolean {
  return record.deleted && nowMs - record.updatedAt >= retentionMs;
}

/** Stamp a freshly-derived payload as a live record at `rev`. Pure. */
export function makeRecord<P>(
  id: string,
  rev: number,
  nowMs: number,
  payload: P,
): SyncRecord<P> {
  return {
    id,
    rev,
    updatedAt: nowMs,
    deleted: false,
    schemaVersion: SYNC_SCHEMA_VERSION,
    payload,
  };
}

/** Stamp a tombstone for a deleted record at `rev`. Pure. */
export function makeTombstone(id: string, rev: number, nowMs: number): SyncRecord<Record<string, never>> {
  return {
    id,
    rev,
    updatedAt: nowMs,
    deleted: true,
    schemaVersion: SYNC_SCHEMA_VERSION,
    payload: {},
  };
}
