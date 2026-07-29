// Per-user paired-Mac backup collection for the TeamPresence DO.
//
// This is the first CLIENT-OWNED sync collection (plans/feat-ios-paired-mac-backup
// /DESIGN.md). Unlike `devices` (server-derived from presence, read-only on the
// phone), `pairedMacs` is written by the phone to back up its local saved-host
// list — including manually typed host/IPs — so the list survives an app
// upgrade, a bundle-id change, or a reinstall.
//
// Privacy: a paired-Mac backup is per USER, not per team. The DO is per team, so
// we scope by PHYSICAL collection name: the logical client collection
// `pairedMacs` maps to `pairedMacs:<ownerUserId>`, where ownerUserId is the
// VERIFIED Stack user id (never client input). This reuses the whole generic
// sync machinery (snapshot/delta/tombstone/GC/epoch) unchanged; only the
// collection string carries the user scope, and outgoing frames are relabeled
// back to the logical name so the client stays oblivious to the suffix.
//
// Writes arrive via a trusted worker RPC (POST /v1/sync/paired-macs ->
// backupPairedMacs), mirroring the Mac heartbeat RPC pattern, rather than
// expanding the live WS inbound surface. Reads ride the existing sync WS.
//
// Pure + storage-bound so it unit-tests against the Map-backed fake, same
// posture as sync.ts / syncStorage.ts.

import { buildDelta, type SyncDeltaFrame, type SyncRecord, type SyncSnapshotFrame } from "./sync";
import type { SyncServerFrame } from "./sync";
import {
  listRecords,
  readRecord,
  tombstoneRecord,
  upsertRecord,
  type SyncStorage,
} from "./syncStorage";
import { sanitizePublishedRoutes } from "./routePrivacy";

/** Logical collection name the client subscribes to and stores under. */
export const PAIRED_MACS_COLLECTION = "pairedMacs";
const SCOPED_PAIRED_MACS_COLLECTION = "pairedMacsScoped";
const IOS_V2_SCOPED_PAIRED_MACS_COLLECTION = "pairedMacsScopedIosV2";
const IOS_V2_CLIENT_SCOPE_PREFIX = "ios:v2:";
export const PAIRED_MACS_COLLECTION_TOMBSTONE_PREFIXES = [
  `${PAIRED_MACS_COLLECTION}:`,
  `${SCOPED_PAIRED_MACS_COLLECTION}:`,
  `${IOS_V2_SCOPED_PAIRED_MACS_COLLECTION}:`,
];

/** Max saved-host records a single user may back up. Bounds the storage a client
 * can create, mirroring MAX_DEVICES_PER_TEAM for the device registry. */
export const MAX_PAIRED_MACS_PER_USER = 200;

/** Max TOTAL records (live + retained tombstones) a single user's collection may
 * hold. Bounds storage against create/delete churn within the GC retention
 * window: a delete leaves a tombstone, so a live-only cap lets a client cycle new
 * ids → delete → repeat unbounded. 5× the live cap leaves generous headroom for
 * legitimate forget/re-pair while capping the abuse vector. */
export const MAX_PAIRED_MAC_RECORDS_PER_USER = MAX_PAIRED_MACS_PER_USER * 5;
/** Max tagged-build backup scopes one user may create per supported storage
 * generation. Scopes are client-provided dev-build labels, so the server bounds
 * their count before using them in a physical collection name. The deprecated
 * iOS v1 and current iOS v2 generations have separate namespaces: stale
 * v1 heads cannot deny v2 capacity. The larger bound supports many concurrent
 * development builds while remaining finite; at capacity, only a scope with no
 * activity for 24 hours may be recycled. */
export const MAX_PAIRED_MAC_CLIENT_SCOPES_PER_USER = 256;
export const PAIRED_MAC_CLIENT_SCOPE_INACTIVE_MS = 24 * 60 * 60 * 1_000;

/** Max ops accepted in one backup request. A full reconcile pushes at most the
 * whole list, so the per-user cap is the natural bound. */
export const MAX_BACKUP_OPS = MAX_PAIRED_MACS_PER_USER;

/** Max length of a backed-up Mac id / display name (mirrors the registry/presence
 * display-name bound and a generous id bound). */
export const MAX_MAC_ID_LENGTH = 256;
export const MAX_DISPLAY_NAME_LENGTH = 128;
export const MAX_INSTANCE_TAG_LENGTH = 64;
export const MAX_CLIENT_SCOPE_LENGTH = 128;
const SYNC_HEAD_PREFIX = "synchead:";
const SCOPE_ACTIVITY_PREFIX = "pairedmacscopeactivity:";
const PAIRED_MAC_INSTANCE_SEPARATOR = "\u001f";

/** Storage identity for one physical Mac app instance. Legacy untagged records
 * keep their historical physical-device id. */
export function pairedMacBackupID(macDeviceID: string, instanceTag?: string | null): string {
  const tag = trimmedString(instanceTag);
  return tag ? `${macDeviceID}${PAIRED_MAC_INSTANCE_SEPARATOR}${tag}` : macDeviceID;
}
/** Route bounds mirror validate.ts so the backup payload can't exceed what a
 * heartbeat could push. */
export const MAX_ROUTES = 16;
export const MAX_ROUTES_TOTAL_BYTES = 2048;

/** Max request body for a paired-Mac backup POST. Sized to the DECLARED limits
 * (the shared 16 KiB heartbeat cap is far too small: a full reconcile pushes up
 * to MAX_BACKUP_OPS ops, each up to MAX_ROUTES_TOTAL_BYTES of routes plus id /
 * display name / timestamps / JSON overhead). Derived as ~3 KiB/op + a small
 * envelope so a legitimate large backup is accepted instead of 413'd and
 * silently dropped by the best-effort client. The bounded reader still aborts
 * early past this cap. */
export const MAX_PAIRED_MAC_BACKUP_BYTES =
  MAX_BACKUP_OPS * (MAX_ROUTES_TOTAL_BYTES + 1024) + 2048;

/** The backup payload mirrors the iOS `MobilePairedMac` row. Legacy routes stay
 * opaque, while Iroh routes are reduced to EndpointID plus an approved managed
 * relay URL before persistence and again before restore. */
export interface PairedMacBackupRecord {
  macDeviceID: string;
  displayName?: string;
  /** Authenticated Mac app-instance identity that owns the reconnect routes. */
  instanceTag?: string;
  routes: unknown[];
  /** epoch ms */
  createdAt: number;
  /** epoch ms; also the render sort key */
  lastSeenAt: number;
  isActive: boolean;
  /** Per-user customizations, opaque to the worker (synced across the user's
   * devices). `customColor` is "palette:<n>" or "#RRGGBB"; `customIcon` is an
   * SF Symbol name or an emoji. */
  customName?: string;
  customColor?: string;
  customIcon?: string;
}

export interface PairedMacBackupSnapshot {
  records: PairedMacBackupRecord[];
  deletedMacDeviceIDs: string[];
}

export type PairedMacBackupOp =
  | {
      kind: "upsert";
      id: string;
      record: PairedMacBackupRecord;
      /** Which customization keys the upload actually CARRIED (were present in the
       * JSON `record`), regardless of value. iOS uploads always carry all three
       * (authoritative; `null` = the user reset that field to Auto). The Mac's
       * route-publish never carries them — it does not know the user's
       * customizations — so the server preserves the stored values for any key
       * NOT provided, instead of clobbering them to empty on every heartbeat.
       * Absent here (e.g. a hand-built op) is treated as "all provided", i.e. the
       * record's custom fields are authoritative as-is. */
      providedCustom?: { name: boolean; color: boolean; icon: boolean };
      /** Whether this client carried `instanceTag`. Older iOS builds omitted it,
       * so their uploads preserve newer stored authority instead of clearing it. */
      providedInstanceTag?: boolean;
      /** Mac self-publishers may claim an empty/same-tag row but cannot switch
       * another authenticated app instance's authority. Routine iOS metadata
       * writes preserve an existing live row's authenticated host authority. */
      instanceTagWriteMode?: "compare_and_set" | "preserve";
      /** Explicit user re-add of an id with a retained server tombstone. Normal
       * route refreshes and full reconciles must leave tombstones authoritative. */
      allowTombstoneRevive?: boolean;
    }
  | { kind: "delete"; id: string };

export type PairedMacBackupParse =
  | { ok: true; ops: PairedMacBackupOp[] }
  | { ok: false; error: string };

export class PairedMacBackupApplyError extends Error {
  constructor(readonly code: "too_many_client_scopes") {
    super(code);
    this.name = "PairedMacBackupApplyError";
  }
}

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

/** Physical per-user collection name. Derived from the VERIFIED user id, with an
 * optional client-owned sub-scope for tagged app builds. The client scope never
 * replaces user/team authorization; it only partitions that user's own backup. */
export function normalizeClientScope(value: unknown): string | null {
  const trimmed = trimmedString(value);
  if (!trimmed) return null;
  if (trimmed.length > MAX_CLIENT_SCOPE_LENGTH) return null;
  return `b64_${base64URL(new TextEncoder().encode(trimmed))}`;
}

function scopedPairedMacCollectionNamespace(clientScope: unknown): string {
  const scope = trimmedString(clientScope);
  return scope.startsWith(IOS_V2_CLIENT_SCOPE_PREFIX) && scope.length > IOS_V2_CLIENT_SCOPE_PREFIX.length
    ? IOS_V2_SCOPED_PAIRED_MACS_COLLECTION
    : SCOPED_PAIRED_MACS_COLLECTION;
}

export function pairedMacsCollection(userId: string, clientScope?: string | null): string {
  const scope = normalizeClientScope(clientScope);
  if (!scope) return `${PAIRED_MACS_COLLECTION}:${userId}`;
  return `${scopedPairedMacCollectionNamespace(clientScope)}:${userId}:${scope}`;
}

function scopedPairedMacCollectionHeadPrefix(userId: string, clientScope: string): string {
  return `${SYNC_HEAD_PREFIX}${scopedPairedMacCollectionNamespace(clientScope)}:${userId}:`;
}

function scopedPairedMacActivityPrefix(userId: string, clientScope: string): string {
  return `${SCOPE_ACTIVITY_PREFIX}${scopedPairedMacCollectionNamespace(clientScope)}:${userId}:`;
}

function scopedPairedMacActivityKey(collection: string): string {
  return `${SCOPE_ACTIVITY_PREFIX}${collection}`;
}

async function ensureScopedCollectionCapacity(
  storage: SyncStorage,
  userId: string,
  collection: string,
  clientScope: string,
  nowMs: number,
): Promise<boolean> {
  const heads = await storage.list<number>({ prefix: scopedPairedMacCollectionHeadPrefix(userId, clientScope) });
  if (heads.has(`${SYNC_HEAD_PREFIX}${collection}`)) return true;
  if (heads.size < MAX_PAIRED_MAC_CLIENT_SCOPES_PER_USER) return true;

  const inactiveBefore = nowMs - PAIRED_MAC_CLIENT_SCOPE_INACTIVE_MS;
  const activity = await storage.list<number>({
    prefix: scopedPairedMacActivityPrefix(userId, clientScope),
  });
  let oldest: { collection: string; lastActivityAt: number } | null = null;
  for (const headKey of heads.keys()) {
    const candidateCollection = headKey.slice(SYNC_HEAD_PREFIX.length);
    const activityKey = scopedPairedMacActivityKey(candidateCollection);
    let lastActivityAt = activity.get(activityKey);
    if (lastActivityAt === undefined) {
      // One-time migration for scopes created before activity markers existed.
      const records = await listRecords<PairedMacBackupRecord>(storage, candidateCollection);
      lastActivityAt = records.reduce(
        (latest, record) => Math.max(latest, record.updatedAt),
        0,
      );
    }
    if (lastActivityAt > inactiveBefore) continue;
    if (
      oldest === null ||
      lastActivityAt < oldest.lastActivityAt ||
      (lastActivityAt === oldest.lastActivityAt && candidateCollection < oldest.collection)
    ) {
      oldest = { collection: candidateCollection, lastActivityAt };
    }
  }
  if (oldest === null) return false;
  await deleteScopedCollection(storage, oldest.collection);
  return true;
}

async function deleteScopedCollection(
  storage: SyncStorage,
  collection: string,
): Promise<void> {
  const listPrefixes = [
    `synced:${collection}:`,
    `synctomb:${collection}:`,
  ];
  for (const prefix of listPrefixes) {
    const entries = await storage.list<unknown>({ prefix });
    for (const key of entries.keys()) await storage.delete(key);
  }
  for (const key of [
    `synchead:${collection}`,
    `syncgcfloor:${collection}`,
    `syncbackfill:${collection}`,
    `syncepoch:${collection}`,
    scopedPairedMacActivityKey(collection),
  ]) {
    await storage.delete(key);
  }
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Parse and bound a backup body that has already been JSON-decoded. The body is
 * `{ ops: [{ macDeviceID, deleted?, record? }] }`. Pure for tests. */
export function parsePairedMacBackup(body: Record<string, unknown>): PairedMacBackupParse {
  if (!Array.isArray(body.ops)) return { ok: false, error: "invalid_ops" };
  if (body.ops.length > MAX_BACKUP_OPS) return { ok: false, error: "too_many_ops" };

  const ops: PairedMacBackupOp[] = [];
  const seen = new Set<string>();
  for (const entry of body.ops) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      return { ok: false, error: "invalid_op" };
    }
    const e = entry as Record<string, unknown>;
    const macDeviceID = trimmedString(e.macDeviceID);
    if (!macDeviceID || macDeviceID.length > MAX_MAC_ID_LENGTH) return { ok: false, error: "invalid_mac_id" };
    const opInstanceTag = trimmedString(e.instanceTag);
    if (opInstanceTag.length > MAX_INSTANCE_TAG_LENGTH) {
      return { ok: false, error: "invalid_instance_tag" };
    }
    const id = pairedMacBackupID(macDeviceID, opInstanceTag);
    // The last op for an id wins within a request, but a single request should
    // not carry the same id twice; dedup defensively, keeping the last.
    if (seen.has(id)) {
      const idx = ops.findIndex((o) => o.id === id);
      if (idx >= 0) ops.splice(idx, 1);
    }
    seen.add(id);

    if (e.deleted === true) {
      ops.push({ kind: "delete", id });
      continue;
    }

    const recordRaw = e.record;
    if (recordRaw === null || typeof recordRaw !== "object" || Array.isArray(recordRaw)) {
      return { ok: false, error: "invalid_record" };
    }
    const r = recordRaw as Record<string, unknown>;
    const displayName = trimmedString(r.displayName);
    if (displayName.length > MAX_DISPLAY_NAME_LENGTH) {
      return { ok: false, error: "invalid_display_name" };
    }
    const providedInstanceTag = "instanceTag" in r;
    const instanceTag = trimmedString(r.instanceTag);
    if (instanceTag.length > MAX_INSTANCE_TAG_LENGTH) {
      return { ok: false, error: "invalid_instance_tag" };
    }
    if (opInstanceTag && opInstanceTag !== instanceTag) {
      return { ok: false, error: "instance_tag_mismatch" };
    }
    const rawInstanceTagWriteMode = r.instanceTagWriteMode;
    if (
      rawInstanceTagWriteMode !== undefined &&
      rawInstanceTagWriteMode !== "compare_and_set" &&
      rawInstanceTagWriteMode !== "preserve"
    ) {
      return { ok: false, error: "invalid_instance_tag_write_mode" };
    }
    // User customizations: opaque strings, bounded like the display name. Over-long
    // values are rejected rather than silently truncated. Track whether each key was
    // PRESENT in the upload (vs absent) so the server can preserve a stored value
    // when the Mac route-publish omits it, while still letting an iOS upload clear
    // it (iOS always sends the key, `null` when reset to Auto). See `applyOps`.
    const providedCustom = {
      name: "customName" in r,
      color: "customColor" in r,
      icon: "customIcon" in r,
    };
    const customName = trimmedString(r.customName);
    const customColor = trimmedString(r.customColor);
    const customIcon = trimmedString(r.customIcon);
    if (
      customName.length > MAX_DISPLAY_NAME_LENGTH ||
      customColor.length > MAX_DISPLAY_NAME_LENGTH ||
      customIcon.length > MAX_DISPLAY_NAME_LENGTH
    ) {
      return { ok: false, error: "invalid_customization" };
    }
    const createdAt = finiteNumber(r.createdAt);
    const lastSeenAt = finiteNumber(r.lastSeenAt);
    if (createdAt === null || lastSeenAt === null) {
      return { ok: false, error: "invalid_timestamps" };
    }
    if (!Array.isArray(r.routes)) return { ok: false, error: "invalid_routes" };
    // Same entry-count + cumulative-byte bound as the heartbeat route parse:
    // keep only plain objects, preferred-first prefix, stop at the byte budget.
    const routes: unknown[] = [];
    let routeBytes = 0;
    for (const route of r.routes) {
      if (route === null || typeof route !== "object" || Array.isArray(route)) continue;
      if (routes.length >= MAX_ROUTES) break;
      routeBytes += JSON.stringify(route).length;
      if (routeBytes > MAX_ROUTES_TOTAL_BYTES) break;
      routes.push(route);
    }

    ops.push({
      kind: "upsert",
      id,
      providedCustom,
      providedInstanceTag,
      instanceTagWriteMode: rawInstanceTagWriteMode,
      allowTombstoneRevive: e.reviveDeleted === true,
      record: {
        macDeviceID,
        displayName: displayName || undefined,
        instanceTag: instanceTag || undefined,
        routes: sanitizePublishedRoutes(routes) ?? [],
        createdAt,
        lastSeenAt,
        isActive: r.isActive === true,
        customName: customName || undefined,
        customColor: customColor || undefined,
        customIcon: customIcon || undefined,
      },
    });
  }

  return { ok: true, ops };
}

/** List-shape equality for a backup record: compare identity, display name,
 * routes, and active flag, but IGNORE the timestamps. `lastSeenAt` drifts on
 * every route refresh, so comparing it would re-mint a rev (and broadcast a
 * delta) on every heartbeat-driven upsert and on every full reconcile push,
 * defeating the no-op optimization. Mirrors the device-list collection's
 * shape-aware compare (which ignores per-tick freshness). The stored
 * `lastSeenAt` therefore tracks the last SHAPE change, which is the right
 * as-of-rev semantics for restore ordering. */
export function pairedMacShapeEqual(a: PairedMacBackupRecord, b: PairedMacBackupRecord): boolean {
  return (
    a.macDeviceID === b.macDeviceID &&
    (a.displayName ?? "") === (b.displayName ?? "") &&
    (a.instanceTag ?? "") === (b.instanceTag ?? "") &&
    a.isActive === b.isActive &&
    // User customizations are part of the shape: a rename / color / icon change
    // must mint a rev and broadcast so the user's other devices receive it.
    (a.customName ?? "") === (b.customName ?? "") &&
    (a.customColor ?? "") === (b.customColor ?? "") &&
    (a.customIcon ?? "") === (b.customIcon ?? "") &&
    JSON.stringify(a.routes) === JSON.stringify(b.routes)
  );
}

export function sanitizePairedMacRecord(record: PairedMacBackupRecord): PairedMacBackupRecord {
  return {
    ...record,
    routes: sanitizePublishedRoutes(record.routes) ?? [],
  };
}

/** Sanitize pre-hardening backup snapshots/deltas immediately before sending. */
export function sanitizePairedMacSyncFrame<Frame extends SyncServerFrame<PairedMacBackupRecord>>(
  frame: Frame,
): Frame {
  if (frame.type === "sync.tick") return frame;
  return {
    ...frame,
    records: frame.records.map((record) => record.deleted
      ? record
      : { ...record, payload: sanitizePairedMacRecord(record.payload) }),
  } as Frame;
}

/** Relabel a frame's collection from the physical per-user name back to the
 * logical `pairedMacs` so the client never sees (or stores under) the user-id
 * suffix. The rev space is the physical collection's, and each user/scope pair
 * has exactly one physical collection, so the client's logical cursor tracks it
 * 1:1. */
export function relabelDelta<P>(delta: SyncDeltaFrame<P>): SyncDeltaFrame<P> {
  return { ...delta, collection: PAIRED_MACS_COLLECTION };
}

export function relabelSnapshot<P>(page: SyncSnapshotFrame<P>): SyncSnapshotFrame<P> {
  return { ...page, collection: PAIRED_MACS_COLLECTION };
}

/** Count the live (non-tombstone) backup records a user currently has, to
 * enforce the per-user cap on NEW ids. */
/** Apply a batch of backup ops for one user against their physical collection,
 * returning the deltas (relabeled to the logical name) the DO should broadcast
 * to that user's subscribed sockets. An unchanged payload is a no-op (no rev
 * churn). A new id beyond the per-user cap is dropped. Storage writes reuse the
 * generic, already-tested `upsertRecord` / `tombstoneRecord`. */
export async function applyBackupOps(
  storage: SyncStorage,
  userId: string,
  ops: readonly PairedMacBackupOp[],
  nowMs: number,
  clientScope?: string | null,
): Promise<SyncDeltaFrame<unknown>[]> {
  const collection = pairedMacsCollection(userId, clientScope);
  const scope = normalizeClientScope(clientScope);
  if (scope && !(await ensureScopedCollectionCapacity(
    storage,
    userId,
    collection,
    clientScope ?? "",
    nowMs,
  ))) {
    throw new PairedMacBackupApplyError("too_many_client_scopes");
  }
  // One listing gives both the live count (cap on visible Macs) AND the total
  // record count (live + RETAINED tombstones). Capping the total bounds storage
  // against create/delete churn: a delete keeps a tombstone for the GC retention
  // window, so live-only capping lets a client cycle 200 new ids → delete → repeat
  // and grow the DO without bound. A brand-new id consumes a new storage slot.
  // Explicitly reviving a tombstoned id reuses its slot (no total growth) and is
  // gated only on the live cap.
  const existingRecords = await listRecords<PairedMacBackupRecord>(storage, collection);
  let liveCount = existingRecords.filter((r) => !r.deleted).length;
  let totalCount = existingRecords.length;
  // Upsert and tombstone deltas carry different payload shapes (the record vs.
  // `{}`); both serialize the same on the wire, so collect them as unknown.
  const deltas: SyncDeltaFrame<unknown>[] = [];

  for (const op of ops) {
    if (op.kind === "delete") {
      const existing = await readRecord<PairedMacBackupRecord>(storage, collection, op.id);
      const res = await tombstoneRecord(storage, collection, op.id, nowMs);
      if (res.delta !== null) {
        if (existing !== undefined && !existing.deleted) liveCount = Math.max(0, liveCount - 1);
        deltas.push(relabelDelta(res.delta));
      }
      continue;
    }
    const exactExisting = await readRecord<PairedMacBackupRecord>(storage, collection, op.id);
    let existing = exactExisting;
    let migratingLegacyID: string | null = null;
    if (existing === undefined && op.id !== op.record.macDeviceID) {
      const legacy = await readRecord<PairedMacBackupRecord>(
        storage,
        collection,
        op.record.macDeviceID,
      );
      if (
        legacy !== undefined &&
        !legacy.deleted &&
        (legacy.payload.instanceTag ?? "") === (op.record.instanceTag ?? "")
      ) {
        existing = legacy;
        migratingLegacyID = op.record.macDeviceID;
      }
    }
    const isBrandNew = existing === undefined;
    const isReviving = exactExisting !== undefined && exactExisting.deleted;
    const createsStorageSlot = exactExisting === undefined;
    if (isReviving && op.allowTombstoneRevive !== true) {
      // A delete tombstone is the authoritative "forget" operation. Stale
      // devices can republish ordinary upserts with newer lastSeenAt values, so
      // timestamps must not be used as a revive signal. Ignore every ordinary
      // upsert while a tombstone exists; only an explicit re-add path may send
      // allowTombstoneRevive.
      continue;
    }
    const addsLive = isBrandNew || isReviving;
    if (addsLive && liveCount >= MAX_PAIRED_MACS_PER_USER) {
      // At the live cap: drop new entries rather than fail the whole batch,
      // mirroring the preferred-first leniency elsewhere. Existing records update.
      continue;
    }
    if (createsStorageSlot && totalCount >= MAX_PAIRED_MAC_RECORDS_PER_USER) {
      // At the cumulative (live + retained-tombstone) cap: refuse a truly-new id
      // until GC frees tombstones, so create/delete churn cannot amplify storage.
      continue;
    }
    // Preserve stored customizations for any custom key this upload did NOT carry.
    // The Mac's route-publish never sends them, so without this a Mac heartbeat
    // would mint a new rev that wipes the name/color/icon the user set from iOS,
    // and the next restore would clear them. iOS always sends all three keys (it is
    // authoritative, including a `null` reset-to-Auto), so its uploads keep full
    // control. Only meaningful when there is a live existing record to inherit from.
    const record = sanitizePairedMacRecord(op.record);
    const provided = op.providedCustom ?? { name: true, color: true, icon: true };
    if (existing !== undefined && !existing.deleted) {
      const prev = existing.payload;
      const preservesExistingAuthority = op.instanceTagWriteMode === "preserve";
      const legacyCannotReplaceAuthority =
        !preservesExistingAuthority && !(op.providedInstanceTag ?? true) && prev.instanceTag;
      const publisherCannotSwitchAuthority =
        op.instanceTagWriteMode === "compare_and_set" &&
        !!prev.instanceTag &&
        prev.instanceTag !== record.instanceTag;
      if (legacyCannotReplaceAuthority || publisherCannotSwitchAuthority) {
        // A pre-instance-identity client cannot atomically identify the Mac
        // process that supplied its record. Ignore the WHOLE stale operation so
        // its routes, active bit, and freshness cannot make the retained tag's
        // payload appear newly authoritative. A Mac self-publisher has the same
        // CAS rule when another nonnil tag owns the row. Explicit authenticated
        // iOS pairing uploads carry the key without CAS and may switch authority.
        continue;
      }
      if (preservesExistingAuthority) {
        // Active selection and user customization writes do not authenticate a
        // Mac process. Keep the server's current host-owned authority tuple even
        // when the phone's local row is stale, while still applying the metadata
        // fields below. A missing/tombstoned row has no authority to preserve and
        // is created/revived from the incoming snapshot instead.
        record.displayName = prev.displayName;
        record.instanceTag = prev.instanceTag;
        record.routes = prev.routes;
        record.createdAt = prev.createdAt;
        record.lastSeenAt = Math.max(prev.lastSeenAt, record.lastSeenAt);
      }
      if (!provided.name) record.customName = prev.customName;
      if (!provided.color) record.customColor = prev.customColor;
      if (!provided.icon) record.customIcon = prev.customIcon;
    }
    if (record.isActive) {
      const clearDeltas = await clearOtherActiveBackupRecords(storage, collection, op.id, nowMs);
      deltas.push(...clearDeltas);
    }
    const res = await upsertRecord<PairedMacBackupRecord>(
      storage,
      collection,
      op.id,
      record,
      nowMs,
      pairedMacShapeEqual,
      // Refresh `lastSeenAt` in place on a same-shape republish (no rev/delta), so
      // the iOS LWW restore treats a Mac re-confirming its current live route as
      // fresh rather than skipping it and dialing a dead local route.
      (record) => record.lastSeenAt,
    );
    if (res.delta !== null) {
      if (addsLive) liveCount += 1;
      if (createsStorageSlot) totalCount += 1;
      deltas.push(relabelDelta(res.delta));
    }
    if (migratingLegacyID !== null) {
      const retired = await tombstoneRecord(storage, collection, migratingLegacyID, nowMs);
      if (retired.delta !== null) {
        deltas.push(relabelDelta(retired.delta));
      }
    }
  }

  if (scope && await storage.get<number>(`${SYNC_HEAD_PREFIX}${collection}`) !== undefined) {
    await storage.put(scopedPairedMacActivityKey(collection), nowMs);
  }
  return deltas;
}

async function clearOtherActiveBackupRecords(
  storage: SyncStorage,
  collection: string,
  activeID: string,
  nowMs: number,
): Promise<SyncDeltaFrame<unknown>[]> {
  const records = await listRecords<PairedMacBackupRecord>(storage, collection);
  const deltas: SyncDeltaFrame<unknown>[] = [];
  for (const stored of records) {
    if (stored.deleted || stored.id === activeID || !stored.payload.isActive) continue;
    const next = { ...sanitizePairedMacRecord(stored.payload), isActive: false };
    const res = await upsertRecord<PairedMacBackupRecord>(
      storage,
      collection,
      stored.id,
      next,
      nowMs,
      pairedMacShapeEqual,
      (record) => record.lastSeenAt,
    );
    if (res.delta !== null) {
      deltas.push(relabelDelta(res.delta));
    }
  }
  return deltas;
}

/** The live (non-tombstone) backup records for a user, newest-first by
 * `lastSeenAt`. Backs the GET restore path: the phone fetches this on sign-in
 * and merges it into its local store. Returns the payloads only (the wire
 * `rev`/tombstone bookkeeping is internal to the sync machinery). */
export async function listLiveBackup(
  storage: SyncStorage,
  userId: string,
  clientScope?: string | null,
): Promise<PairedMacBackupRecord[]> {
  return (await listBackupSnapshot(storage, userId, clientScope)).records;
}

/** The full restore snapshot for a user: live records plus delete tombstones.
 * The iOS restore applies `deletedMacDeviceIDs` before live records so a delete
 * made on another device removes stale local rows and prevents later stale
 * route-refresh uploads from reviving them. */
export async function listBackupSnapshot(
  storage: SyncStorage,
  userId: string,
  clientScope?: string | null,
): Promise<PairedMacBackupSnapshot> {
  const all = await listRecords<PairedMacBackupRecord>(storage, pairedMacsCollection(userId, clientScope));
  const records = all
    .filter((r) => !r.deleted)
    .map((r) => sanitizePairedMacRecord(r.payload))
    .sort((a, b) => (b?.lastSeenAt ?? 0) - (a?.lastSeenAt ?? 0));
  const deletedMacDeviceIDs = all
    .filter((r) => r.deleted)
    .map((r) => r.id)
    .sort();
  return { records, deletedMacDeviceIDs };
}

/** Re-export so the DO can build an empty delta if it ever needs to. */
export { buildDelta };
export type { SyncRecord };
