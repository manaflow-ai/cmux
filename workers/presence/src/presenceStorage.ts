// Storage-bound presence removal lifecycle for the TeamPresence DO: the key
// space for instance records and owner pins, signout removal, the orphaned
// owner-pin sweep, and the account-deletion purge. Written against the same
// minimal `SyncStorage` interface as syncStorage.ts so it unit-tests against a
// Map-backed fake without the Workers runtime; do.ts wires it to `ctx.storage`
// and owns broadcasting the returned events and deltas.

import {
  applyHeartbeat,
  removalOfflineEvents,
  type HeartbeatInput,
  type PresenceEvent,
  type PresenceInstance,
} from "./core";
import { reconcileSingleDevice, type DeviceRecord } from "./syncDevices";
import type { SyncDeltaFrame } from "./sync";
import type { SyncStorage } from "./syncStorage";

export const INSTANCE_PREFIX = "inst:";
/** `owner:<deviceId>` -> Stack user id pinned on first heartbeat. Durable
 * while the device has any `inst:` record; released once it has none (a
 * signout goodbye removed the last instance, the alarm's 24h prune sweep did,
 * or an admin purge did; see checkDeviceOwner in core.ts for the re-claim
 * tradeoff). Bounded by MAX_DEVICES_PER_TEAM (owner pins are the DO's device
 * records). */
export const OWNER_PREFIX = "owner:";

export function instanceKey(deviceId: string, tag: string): string {
  // deviceId is a validated fixed-format UUID, so the composite key is
  // unambiguous even though tags may contain ":".
  return `${INSTANCE_PREFIX}${deviceId}:${tag}`;
}

export function ownerKey(deviceId: string): string {
  return `${OWNER_PREFIX}${deviceId}`;
}

export interface SignoutRemoval {
  /** The goodbye-shaped offline record echoed in the heartbeat response. */
  instance: PresenceInstance;
  /** Presence events to broadcast (an offline goodbye iff it was online). */
  events: PresenceEvent[];
  /** Sync deltas to broadcast: the device's tombstone when this was its last
   * instance, or its updated record when other tags remain. */
  deltas: SyncDeltaFrame<DeviceRecord>[];
  /** True when the device's last instance went away and the pin was released. */
  ownerPinReleased: boolean;
}

/** Apply a signout goodbye (`stopping: true, signout: true`) to a KNOWN
 * instance: the app instance signed out of its account, so unlike a plain
 * goodbye (which flips the record offline and keeps it), the `inst:` record is
 * DELETED, the synced device record is tombstoned when no instance remains,
 * and the `owner:` pin is released with the last instance. The offline event
 * keeps reason "goodbye" so old client decoders (which know only
 * "timeout" | "goodbye") keep working. The caller has already enforced the
 * owner guard and handled the never-seen no-op case. */
export async function removeInstanceForSignout(
  storage: SyncStorage,
  existing: PresenceInstance,
  beat: HeartbeatInput,
  nowMs: number,
): Promise<SignoutRemoval> {
  // Same pure goodbye transition as a plain stopping beat (offline event only
  // when the instance was online), then removal instead of a stored record.
  const { instance, events } = applyHeartbeat(existing, beat, nowMs);
  await storage.delete(instanceKey(beat.deviceId, beat.tag));
  const remaining = [...(await storage.list<PresenceInstance>({
    prefix: `${INSTANCE_PREFIX}${beat.deviceId}:`,
  })).values()];
  let ownerPinReleased = false;
  if (remaining.length === 0) {
    await storage.delete(ownerKey(beat.deviceId));
    ownerPinReleased = true;
  }
  // Sync projection is BEST-EFFORT and isolated, exactly like the heartbeat
  // path in do.ts: presence removal already happened above and must not turn
  // into a 5xx because the additive sync layer hiccupped.
  const deltas: SyncDeltaFrame<DeviceRecord>[] = [];
  try {
    const owner = ownerPinReleased
      ? undefined
      : await storage.get<string>(ownerKey(beat.deviceId));
    const delta = await reconcileSingleDevice(storage, beat.deviceId, remaining, owner, nowMs);
    if (delta !== null) deltas.push(delta);
  } catch (err) {
    console.error("sync projection failed (signout); presence unaffected", err);
  }
  return { instance, events, deltas, ownerPinReleased };
}

/** Release `owner:` pins whose device has no `inst:` record left. The alarm
 * calls this after its prune pass, so a device that has been fully offline for
 * the 24h retention (or whose records were removed by signout/purge without a
 * sweep) stops holding its claim. Returns the released device ids. */
export async function sweepOrphanedOwnerPins(
  storage: SyncStorage,
  liveDeviceIds: ReadonlySet<string>,
): Promise<string[]> {
  const owners = await storage.list<string>({ prefix: OWNER_PREFIX });
  const released: string[] = [];
  for (const key of owners.keys()) {
    const deviceId = key.slice(OWNER_PREFIX.length);
    if (liveDeviceIds.has(deviceId)) continue;
    await storage.delete(key);
    released.push(deviceId);
  }
  return released;
}

export interface PurgeUserResult {
  /** Devices whose `owner:` pin matched the purged user and were removed. */
  devicesPurged: number;
  /** Offline goodbyes for the purged instances that were online. */
  events: PresenceEvent[];
  /** Device tombstone deltas for the purged devices' synced records. */
  deltas: SyncDeltaFrame<DeviceRecord>[];
}

/** Account-deletion purge: remove every device the user owns from this team's
 * presence map. Deletes each pinned device's `inst:` records and its `owner:`
 * pin, tombstones the synced device records, and derives the offline events
 * (reason "goodbye", for old-decoder compat) for instances that were online.
 * Devices pinned to other users are untouched. */
export async function purgeUserDevices(
  storage: SyncStorage,
  userId: string,
  nowMs: number,
): Promise<PurgeUserResult> {
  const owners = await storage.list<string>({ prefix: OWNER_PREFIX });
  const events: PresenceEvent[] = [];
  const purgedDeviceIds: string[] = [];
  for (const [key, ownerUserId] of owners) {
    if (ownerUserId !== userId) continue;
    const deviceId = key.slice(OWNER_PREFIX.length);
    const instances = await storage.list<PresenceInstance>({
      prefix: `${INSTANCE_PREFIX}${deviceId}:`,
    });
    for (const [instKey, instance] of instances) {
      events.push(...removalOfflineEvents([instance], nowMs));
      await storage.delete(instKey);
    }
    await storage.delete(key);
    purgedDeviceIds.push(deviceId);
  }
  // Sync projection stays best-effort here too: the presence purge above is
  // the durable outcome; a failed tombstone is repaired by the next alarm's
  // full reconcile.
  const deltas: SyncDeltaFrame<DeviceRecord>[] = [];
  try {
    for (const deviceId of purgedDeviceIds) {
      const delta = await reconcileSingleDevice(storage, deviceId, [], undefined, nowMs);
      if (delta !== null) deltas.push(delta);
    }
  } catch (err) {
    console.error("sync projection failed (purge); presence unaffected", err);
  }
  return { devicesPurged: purgedDeviceIds.length, events, deltas };
}
