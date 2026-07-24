// Device-list collection: the first consumer of the generic sync substrate.
//
// The `devices` collection's records are a PROJECTION of the presence state
// machine (core.ts). The DO already holds, per team, the live instance map
// (`inst:<deviceId>:<tag>`) and the durable owner pins (`owner:<deviceId>`).
// This module folds those into one `DeviceRecord` per device — the durable
// list shape the iOS device tree renders — and decides whether that shape
// changed enough to mint a new sync `rev`.
//
// Deliberately NOT carried in the record: live `online` and per-tick
// `lastSeenAt`. Those change on every 15s heartbeat and would churn the cursor
// for no list-shape change (DESIGN.md §4.2). Liveness stays on the existing
// presence event stream (online/offline/seen/routes), which the client overlays
// onto these rows exactly as today. The record's `lastSeenAtAtRev` is a stable
// as-of-this-rev value, used only to seed "last seen ~N ago" with no live link.
//
// Pure and synchronous so it unit-tests without the Workers runtime.

import type { PresenceInstance, PresenceRoute } from "./core";
import {
  listRecords,
  tombstoneRecord,
  upsertRecord,
  type StoredSyncRecord,
  type SyncStorage,
  type SyncWriteResult,
} from "./syncStorage";
import {
  buildDelta,
  type SyncDeltaFrame,
  type SyncServerFrame,
} from "./sync";
import { sanitizePublishedRoutes } from "./routePrivacy";

export const DEVICES_COLLECTION = "devices";

/** One tagged app instance inside a device record. List-shape fields only. */
export interface DeviceInstanceRecord {
  tag: string;
  /** Registry-mirrored routes after the presence publication policy. */
  routes: PresenceRoute[];
  /** Last-seen epoch ms AS OF the rev this record was stamped at. Not live. */
  lastSeenAtAtRev: number;
}

/** The durable device-list record the iOS tree renders. */
export interface DeviceRecord {
  deviceId: string;
  platform: string;
  displayName?: string;
  /** Owner pin (the Stack user id that owns this device), for display/trust. */
  ownerUserId?: string;
  /** Last-seen epoch ms AS OF this rev (max over instances). Not live. */
  lastSeenAtAtRev: number;
  /** Tagged app instances on this device, newest-first. */
  instances: DeviceInstanceRecord[];
}

/** Build the device record for one device from its presence instances and owner
 * pin. `instances` must all share `deviceId`; an empty array yields null (the
 * device has no instances and should be a tombstone, not a record). Pure. */
export function deriveDeviceRecord(
  deviceId: string,
  instances: readonly PresenceInstance[],
  ownerUserId: string | undefined,
): DeviceRecord | null {
  if (instances.length === 0) return null;
  const sorted = [...instances].sort((a, b) => b.lastSeenAt - a.lastSeenAt);
  const newest = sorted[0]!;
  return {
    deviceId,
    platform: newest.platform,
    displayName: sorted.find((i) => i.displayName !== undefined)?.displayName,
    ...(ownerUserId !== undefined ? { ownerUserId } : {}),
    lastSeenAtAtRev: newest.lastSeenAt,
    instances: sorted.map((i) => ({
      tag: i.tag,
      routes: sanitizePublishedRoutes(i.routes) ?? [],
      lastSeenAtAtRev: i.lastSeenAt,
    })),
  };
}

/** Whether the LIST-SHAPE of two device records differs enough to mint a new
 * `rev`. Identity (platform, displayName, owner), the tag set, and per-tag
 * routes are list-shape; a per-tick `lastSeenAtAtRev` bump alone is NOT (it
 * would churn the cursor every heartbeat). So this compares everything except
 * the bare timestamps, and treats a routes change or a tag added/removed as a
 * shape change. Pure (DESIGN.md §5.2).
 *
 * Returns true when `next` should be written at a new rev. */
export function deviceShapeChanged(
  prev: DeviceRecord | undefined,
  next: DeviceRecord,
): boolean {
  if (prev === undefined) return true;
  if (prev.platform !== next.platform) return true;
  if (prev.displayName !== next.displayName) return true;
  if (prev.ownerUserId !== next.ownerUserId) return true;
  if (prev.instances.length !== next.instances.length) return true;
  // Order-insensitive by tag: a heartbeat re-sort by lastSeenAt must not look
  // like a shape change. Compare each tag's routes.
  const prevByTag = new Map(prev.instances.map((i) => [i.tag, i]));
  for (const inst of next.instances) {
    const prior = prevByTag.get(inst.tag);
    if (prior === undefined) return true; // tag added
    if (!routesEqual(prior.routes, inst.routes)) return true;
  }
  return false;
}

/** Order-sensitive route-set equality (hosts publish a priority-ordered list,
 * so order is meaning). Small bounded JSON, so JSON.stringify compare is fine —
 * a false "changed" only costs one extra delta. Mirrors core.ts routesEqual but
 * kept local so the sync layer does not depend on presence internals. Pure. */
export function routesEqual(
  a: readonly PresenceRoute[],
  b: readonly PresenceRoute[],
): boolean {
  if (a.length !== b.length) return false;
  return JSON.stringify(a) === JSON.stringify(b);
}

/** Payload equality used by the device-list `upsertRecord`: two DeviceRecords
 * are "the same" iff their list-shape matches, ignoring the per-tick
 * `lastSeenAtAtRev`. This is the inverse of `deviceShapeChanged`, adapted to the
 * stored-vs-derived comparison the generic upsert expects. */
export function deviceRecordEqual(stored: DeviceRecord, next: DeviceRecord): boolean {
  return !deviceShapeChanged(stored, next);
}

/** Defensively scrub records read from pre-hardening sync storage. */
export function sanitizeDeviceRecord(record: DeviceRecord): DeviceRecord {
  return {
    ...record,
    instances: record.instances.map((instance) => ({
      ...instance,
      routes: sanitizePublishedRoutes(instance.routes) ?? [],
    })),
  };
}

/** Sanitize stored device snapshots/deltas immediately before publication. */
export function sanitizeDeviceSyncFrame<Frame extends SyncServerFrame<DeviceRecord>>(
  frame: Frame,
): Frame {
  if (frame.type === "sync.tick") return frame;
  return {
    ...frame,
    records: frame.records.map((record) => record.deleted
      ? record
      : { ...record, payload: sanitizeDeviceRecord(record.payload) }),
  } as Frame;
}

/** Reconcile the whole `devices` collection against the DO's current presence
 * state in one pass. This is the single derivation hook called from BOTH DO
 * write paths (heartbeat and alarm), since list-shape changes happen on both
 * (DESIGN.md §5.2):
 *
 *   - A device with at least one instance: derive its record and upsert it. The
 *     upsert mints a new rev only if the list-shape changed, so a steady-state
 *     `seen` tick or an online↔offline flip (which does not change the stored
 *     record, since the record carries no `online`) is a no-op.
 *   - A device that has a stored live record but NO presence instances left
 *     (its last instance was pruned): tombstone it — it left the list.
 *
 * Returns the delta frames to broadcast (only the records that actually
 * changed). Empty when nothing list-shape-relevant changed, which is the common
 * steady-state case. The caller broadcasts these on the same socket as presence
 * events, additively (DESIGN.md §5.2). */
export async function reconcileDeviceRecords(
  storage: SyncStorage,
  instancesByDevice: Map<string, PresenceInstance[]>,
  ownerByDevice: Map<string, string | undefined>,
  nowMs: number,
): Promise<SyncDeltaFrame<DeviceRecord>[]> {
  const deltas: SyncDeltaFrame<DeviceRecord>[] = [];

  // 1. Upsert a record for every device that currently has instances.
  const livingDeviceIds = new Set<string>();
  for (const [deviceId, instances] of instancesByDevice) {
    const record = deriveDeviceRecord(deviceId, instances, ownerByDevice.get(deviceId));
    if (record === null) continue;
    livingDeviceIds.add(deviceId);
    const result: SyncWriteResult<DeviceRecord> = await upsertRecord(
      storage,
      DEVICES_COLLECTION,
      deviceId,
      record,
      nowMs,
      deviceRecordEqual,
    );
    if (result.delta !== null) deltas.push(result.delta);
  }

  // 2. Tombstone any stored LIVE record whose device no longer has instances.
  //    A device whose last instance was pruned (24h offline) leaves the list.
  const stored = await listRecords<DeviceRecord>(storage, DEVICES_COLLECTION);
  for (const rec of stored) {
    if (rec.deleted) continue;
    if (livingDeviceIds.has(rec.id)) continue;
    const result = await tombstoneRecord(storage, DEVICES_COLLECTION, rec.id, nowMs);
    if (result.delta !== null) {
      // tombstoneRecord returns a `Record<string, never>` payload delta; the
      // device-list facade treats a deleted record's payload as absent, so the
      // cast to the collection's record type is purely structural.
      deltas.push(buildDelta(DEVICES_COLLECTION, result.head, result.delta.records as never));
    }
  }

  return deltas;
}

/** Reconcile ONE device's sync record from its current instances. This is the
 * heartbeat hot-path entry (DESIGN.md §5.2): a heartbeat changes exactly one
 * device, so reconciling the whole collection on every ~15s beat would be
 * O(team size) per beat, O(N^2) per interval at the device cap. Instead the
 * heartbeat passes only the affected device's instances (a single
 * `inst:<deviceId>:` prefix list the DO already does) and owner pin.
 *
 *   - instances non-empty: upsert (mints a rev only on a list-shape change).
 *   - instances empty (the device's last instance just went away on this path,
 *     e.g. a goodbye that removed it): tombstone the stored live record.
 *
 * Returns the delta to broadcast, or null on a no-op. Full-collection tombstone
 * sweeps for devices pruned by the alarm stay in `reconcileDeviceRecords`, which
 * the alarm path calls. */
export async function reconcileSingleDevice(
  storage: SyncStorage,
  deviceId: string,
  instances: readonly PresenceInstance[],
  ownerUserId: string | undefined,
  nowMs: number,
): Promise<SyncDeltaFrame<DeviceRecord> | null> {
  const record = deriveDeviceRecord(deviceId, instances, ownerUserId);
  if (record === null) {
    // No instances left for this device on the heartbeat path: tombstone it if a
    // live record exists (idempotent if already a tombstone or absent).
    const result = await tombstoneRecord(storage, DEVICES_COLLECTION, deviceId, nowMs);
    if (result.delta === null) return null;
    return buildDelta(DEVICES_COLLECTION, result.head, result.delta.records as never);
  }
  const result = await upsertRecord(
    storage,
    DEVICES_COLLECTION,
    deviceId,
    record,
    nowMs,
    deviceRecordEqual,
  );
  return result.delta;
}

/** Group presence instances by deviceId. Helper for `reconcileDeviceRecords`,
 * matching the rollup `buildSnapshot` does. Pure. */
export function groupInstancesByDevice(
  instances: readonly PresenceInstance[],
): Map<string, PresenceInstance[]> {
  const byDevice = new Map<string, PresenceInstance[]>();
  for (const instance of instances) {
    const list = byDevice.get(instance.deviceId) ?? [];
    list.push(instance);
    byDevice.set(instance.deviceId, list);
  }
  return byDevice;
}

/** Read the owner pin for each device from DO storage into a map, for the
 * derivation. Owner keys are `owner:<deviceId>`. */
export function ownersFromList(owners: Map<string, string>): Map<string, string | undefined> {
  const out = new Map<string, string | undefined>();
  for (const [key, userId] of owners) {
    const deviceId = key.startsWith("owner:") ? key.slice("owner:".length) : key;
    out.set(deviceId, userId);
  }
  return out;
}

export type { StoredSyncRecord };
