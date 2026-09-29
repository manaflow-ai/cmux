// Team-wide Cloud machine list (`vms`) sync collection for the TeamPresence DO.
//
// The Mac machines list used to poll `GET /api/vm`. This collection lets the
// web backend push every list-relevant Postgres write (status, name, address,
// slug, creator) into the per-team DO, which broadcasts sync deltas over the
// existing presence WebSocket (`sync.hello` with collection `vms`).
//
// Unlike `devices` (derived from presence) and `pairedMacs` (client-owned,
// per user), `vms` is SERVER-owned: the only writer is the web backend, which
// authenticates with a service secret (no user bearer, because cron writers
// have none). The DO is `idFromName(ownerTeamId)`, the same team scope the
// list route uses, so one team never sees another team's machines.
//
// Postgres remains the source of truth. Every op carries the row's
// `updatedAt` as `sourceUpdatedAtMs`; the DO rejects an op older than what it
// stores, so two concurrent web instances publishing out of order converge on
// the newest row. A `replace` op (published after every list read) carries the
// full visible list plus the time the list was observed; ids the DO holds live
// but the list lacks are tombstoned at that observation time, which a newer
// upsert for the same id still wins against. Payload compares ignore
// `sourceUpdatedAtMs` so a republish of an unchanged row mints no rev.
//
// Pure + storage-bound so it unit-tests against the Map-backed fake, same
// posture as sync.ts / syncStorage.ts / syncPairedMacs.ts.

import type { SyncDeltaFrame, SyncSnapshotFrame } from "./sync";
import {
  listRecords,
  markBackfillDone,
  readBackfillDone,
  readRecord,
  tombstoneRecord,
  upsertRecord,
  type SyncStorage,
} from "./syncStorage";

export const VMS_COLLECTION = "vms";

/** Max ops in one publish. A full `replace` carries at most the team's
 * visible list, and the web list is bounded well below this. */
export const MAX_VM_PUBLISH_OPS = 200;
/** Max records inside one `replace` op (the whole visible list). */
export const MAX_VM_REPLACE_RECORDS = MAX_VM_PUBLISH_OPS;
/** Max request body for a vms publish. ~1 KiB per record covers every bounded
 * string below plus JSON overhead; the bounded reader aborts past this. */
export const MAX_VM_PUBLISH_BYTES = MAX_VM_REPLACE_RECORDS * 1024 + 4096;

const MAX_ID_LENGTH = 256;
const MAX_TEAM_ID_LENGTH = 256;
const MAX_SHORT_STRING_LENGTH = 128;
const MAX_ADDRESS_LENGTH = 64;
const MAX_CAPABILITY_KEYS = 32;
const MAX_CAPABILITY_TRANSPORTS = 8;

/** One machine as the Mac list renders it: the `GET /api/vm` entry shape
 * (`web/app/api/vm/route.ts`) minus per-request fields (`createdBy` names and
 * plan windows, which the client derives or fetches). */
export interface VmRecord {
  /** The provider VM id; the record id and the machine's address. */
  id: string;
  provider: string;
  status: string;
  image: string;
  imageVersion: string | null;
  kind: string;
  /** Provider verbs (`web/services/vms/drivers/types.ts` VmCapabilities). Opaque
   * here beyond bounding; booleans and short string arrays only. */
  capabilities: Record<string, boolean | string[]>;
  /** epoch ms */
  createdAt: number;
  displayName: string | null;
  slug: string | null;
  createdByUserId: string;
  address: { ipv4: string | null; ipv6: string | null };
  /** The Postgres row's `updated_at` (epoch ms): the freshness clock. */
  sourceUpdatedAtMs: number;
}

/** Tombstone payload: keeps the freshness clock so a late older upsert for a
 * destroyed machine is rejected instead of reviving it. */
export interface VmTombstonePayload {
  sourceUpdatedAtMs: number;
}

export type VmPublishOp =
  | { kind: "upsert"; record: VmRecord }
  | { kind: "delete"; id: string; sourceUpdatedAtMs: number }
  | { kind: "replace"; records: VmRecord[]; observedAtMs: number };

export type VmPublishParse =
  | { ok: true; teamId: string; ops: VmPublishOp[] }
  | { ok: false; error: string };

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function boundedNullableString(value: unknown, max: number): string | null | undefined {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (trimmed.length > max) return undefined;
  return trimmed || null;
}

function parseCapabilities(value: unknown): Record<string, boolean | string[]> | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const out: Record<string, boolean | string[]> = {};
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length > MAX_CAPABILITY_KEYS) return null;
  for (const [key, raw] of entries) {
    if (key.length > MAX_SHORT_STRING_LENGTH) return null;
    if (typeof raw === "boolean") {
      out[key] = raw;
      continue;
    }
    if (!Array.isArray(raw) || raw.length > MAX_CAPABILITY_TRANSPORTS) return null;
    const list: string[] = [];
    for (const item of raw) {
      if (typeof item !== "string" || item.length > MAX_SHORT_STRING_LENGTH) return null;
      list.push(item);
    }
    out[key] = list;
  }
  return out;
}

function parseAddress(value: unknown): VmRecord["address"] | null {
  if (value === null || value === undefined) return { ipv4: null, ipv6: null };
  if (typeof value !== "object" || Array.isArray(value)) return null;
  const a = value as Record<string, unknown>;
  const ipv4 = boundedNullableString(a.ipv4, MAX_ADDRESS_LENGTH);
  const ipv6 = boundedNullableString(a.ipv6, MAX_ADDRESS_LENGTH);
  if (ipv4 === undefined || ipv6 === undefined) return null;
  return { ipv4, ipv6 };
}

/** Parse and bound one published record. Returns an error code, or the record. */
export function parseVmRecord(raw: unknown): { ok: true; record: VmRecord } | { ok: false; error: string } {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, error: "invalid_record" };
  }
  const r = raw as Record<string, unknown>;
  const id = trimmedString(r.id);
  if (!id || id.length > MAX_ID_LENGTH) return { ok: false, error: "invalid_id" };
  const provider = trimmedString(r.provider);
  const status = trimmedString(r.status);
  const image = trimmedString(r.image);
  const kind = trimmedString(r.kind);
  const createdByUserId = trimmedString(r.createdByUserId);
  for (const value of [provider, status, image, kind, createdByUserId]) {
    if (!value || value.length > MAX_SHORT_STRING_LENGTH) return { ok: false, error: "invalid_record" };
  }
  const imageVersion = boundedNullableString(r.imageVersion, MAX_SHORT_STRING_LENGTH);
  const displayName = boundedNullableString(r.displayName, MAX_SHORT_STRING_LENGTH);
  const slug = boundedNullableString(r.slug, MAX_SHORT_STRING_LENGTH);
  if (imageVersion === undefined || displayName === undefined || slug === undefined) {
    return { ok: false, error: "invalid_record" };
  }
  const capabilities = parseCapabilities(r.capabilities);
  if (capabilities === null) return { ok: false, error: "invalid_capabilities" };
  const address = parseAddress(r.address);
  if (address === null) return { ok: false, error: "invalid_address" };
  const createdAt = finiteNumber(r.createdAt);
  const sourceUpdatedAtMs = finiteNumber(r.sourceUpdatedAtMs);
  if (createdAt === null || sourceUpdatedAtMs === null) return { ok: false, error: "invalid_timestamps" };
  return {
    ok: true,
    record: {
      id, provider, status, image, imageVersion, kind, capabilities, createdAt,
      displayName, slug, createdByUserId, address, sourceUpdatedAtMs,
    },
  };
}

function parseOp(entry: unknown): { ok: true; op: VmPublishOp } | { ok: false; error: string } {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    return { ok: false, error: "invalid_op" };
  }
  const e = entry as Record<string, unknown>;
  if (e.kind === "upsert") {
    const parsed = parseVmRecord(e.record);
    return parsed.ok ? { ok: true, op: { kind: "upsert", record: parsed.record } } : parsed;
  }
  if (e.kind === "delete") {
    const id = trimmedString(e.id);
    if (!id || id.length > MAX_ID_LENGTH) return { ok: false, error: "invalid_id" };
    const sourceUpdatedAtMs = finiteNumber(e.sourceUpdatedAtMs);
    if (sourceUpdatedAtMs === null) return { ok: false, error: "invalid_timestamps" };
    return { ok: true, op: { kind: "delete", id, sourceUpdatedAtMs } };
  }
  if (e.kind === "replace") {
    if (!Array.isArray(e.records)) return { ok: false, error: "invalid_records" };
    if (e.records.length > MAX_VM_REPLACE_RECORDS) return { ok: false, error: "too_many_records" };
    const observedAtMs = finiteNumber(e.observedAtMs);
    if (observedAtMs === null) return { ok: false, error: "invalid_timestamps" };
    const records: VmRecord[] = [];
    for (const raw of e.records) {
      const parsed = parseVmRecord(raw);
      if (!parsed.ok) return parsed;
      records.push(parsed.record);
    }
    return { ok: true, op: { kind: "replace", records, observedAtMs } };
  }
  return { ok: false, error: "invalid_op_kind" };
}

/** Parse and bound a publish body that has already been JSON-decoded:
 * `{ teamId, ops: [...] }`. `teamId` is trusted (service-to-service auth
 * guards the route) but still bounded. Pure for tests. */
export function parseVmPublish(body: Record<string, unknown>): VmPublishParse {
  const teamId = trimmedString(body.teamId);
  if (!teamId || teamId.length > MAX_TEAM_ID_LENGTH) return { ok: false, error: "invalid_team_id" };
  if (!Array.isArray(body.ops)) return { ok: false, error: "invalid_ops" };
  if (body.ops.length > MAX_VM_PUBLISH_OPS) return { ok: false, error: "too_many_ops" };
  const ops: VmPublishOp[] = [];
  for (const entry of body.ops) {
    const parsed = parseOp(entry);
    if (!parsed.ok) return parsed;
    ops.push(parsed.op);
  }
  return { ok: true, teamId, ops };
}

/** Stamp `vms` snapshot pages with whether a full `replace` has ever landed.
 * Before that the DO holds only rows written since the collection shipped,
 * and the client must not drop machines missing from the snapshot. */
export async function annotateVmSnapshotPages<P>(
  storage: SyncStorage,
  pages: readonly SyncSnapshotFrame<P>[],
): Promise<SyncSnapshotFrame<P>[]> {
  const backfilled = await readBackfillDone(storage, VMS_COLLECTION);
  return pages.map((page) => ({ ...page, backfilled }));
}

/** List-shape equality: everything the list renders, ignoring the freshness
 * clock, so a republish of an unchanged row (every list read publishes a full
 * `replace`) mints no rev and broadcasts nothing. */
export function vmShapeEqual(a: VmRecord, b: VmRecord): boolean {
  const { sourceUpdatedAtMs: _a, ...left } = a;
  const { sourceUpdatedAtMs: _b, ...right } = b;
  return JSON.stringify(left) === JSON.stringify(right);
}

type StoredVm = { deleted: boolean; payload: VmRecord | VmTombstonePayload };

function storedFreshness(stored: StoredVm | undefined): number | null {
  if (stored === undefined) return null;
  const value = (stored.payload as Partial<VmTombstonePayload>).sourceUpdatedAtMs;
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Whether an op stamped `sourceUpdatedAtMs` is older than the stored record
 * and must be dropped. A missing stored clock (never seen) accepts anything. */
function isStale(stored: StoredVm | undefined, sourceUpdatedAtMs: number): boolean {
  const current = storedFreshness(stored);
  return current !== null && sourceUpdatedAtMs < current;
}

async function applyUpsert(
  storage: SyncStorage,
  record: VmRecord,
  nowMs: number,
): Promise<SyncDeltaFrame<unknown> | null> {
  const stored = await readRecord<VmRecord | VmTombstonePayload>(storage, VMS_COLLECTION, record.id);
  if (isStale(stored, record.sourceUpdatedAtMs)) return null;
  // A tombstone stamped at the same clock as this upsert stays a tombstone
  // (`<=`): the delete is the later intent for one row version, and a
  // destroyed row is never listed again.
  if (stored?.deleted && storedFreshness(stored) === record.sourceUpdatedAtMs) return null;
  const res = await upsertRecord<VmRecord>(
    storage,
    VMS_COLLECTION,
    record.id,
    record,
    nowMs,
    vmShapeEqual,
    (payload) => payload.sourceUpdatedAtMs,
  );
  return res.delta;
}

async function applyDelete(
  storage: SyncStorage,
  id: string,
  sourceUpdatedAtMs: number,
  nowMs: number,
): Promise<SyncDeltaFrame<unknown> | null> {
  const stored = await readRecord<VmRecord | VmTombstonePayload>(storage, VMS_COLLECTION, id);
  if (isStale(stored, sourceUpdatedAtMs)) return null;
  // `createIfMissing`: a machine the DO never saw live (its create upsert was
  // lost) still needs a tombstone so its later, older upsert is rejected.
  const res = await tombstoneRecord(storage, VMS_COLLECTION, id, nowMs, {
    createIfMissing: true,
    payload: { sourceUpdatedAtMs } satisfies VmTombstonePayload,
  });
  return res.delta;
}

async function applyReplace(
  storage: SyncStorage,
  records: readonly VmRecord[],
  observedAtMs: number,
  nowMs: number,
): Promise<SyncDeltaFrame<unknown>[]> {
  const deltas: SyncDeltaFrame<unknown>[] = [];
  const listed = new Set<string>();
  for (const record of records) {
    listed.add(record.id);
    const delta = await applyUpsert(storage, record, nowMs);
    if (delta !== null) deltas.push(delta);
  }
  // Ids the DO holds live but the observed list lacks left the list (destroyed,
  // or a lost delete). Tombstone them at the observation time: a machine
  // created after the list was read carries a newer clock and survives.
  const existing = await listRecords<VmRecord | VmTombstonePayload>(storage, VMS_COLLECTION);
  for (const stored of existing) {
    if (stored.deleted || listed.has(stored.id)) continue;
    const delta = await applyDelete(storage, stored.id, observedAtMs, nowMs);
    if (delta !== null) deltas.push(delta);
  }
  // A full list has landed: snapshots from here on are complete, not just the
  // rows written since this collection shipped.
  await markBackfillDone(storage, VMS_COLLECTION);
  return deltas;
}

/** Apply a batch of publish ops for one team, returning the deltas the DO
 * should broadcast. Unchanged payloads and stale ops are no-ops. Storage
 * writes reuse the generic `upsertRecord` / `tombstoneRecord`. */
export async function applyVmOps(
  storage: SyncStorage,
  ops: readonly VmPublishOp[],
  nowMs: number,
): Promise<SyncDeltaFrame<unknown>[]> {
  const deltas: SyncDeltaFrame<unknown>[] = [];
  for (const op of ops) {
    if (op.kind === "upsert") {
      const delta = await applyUpsert(storage, op.record, nowMs);
      if (delta !== null) deltas.push(delta);
    } else if (op.kind === "delete") {
      const delta = await applyDelete(storage, op.id, op.sourceUpdatedAtMs, nowMs);
      if (delta !== null) deltas.push(delta);
    } else {
      deltas.push(...await applyReplace(storage, op.records, op.observedAtMs, nowMs));
    }
  }
  return deltas;
}
