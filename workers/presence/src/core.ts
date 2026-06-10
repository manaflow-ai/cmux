// Pure presence state machine for the cmux device presence service.
//
// One team's presence is a map of app instances keyed by (deviceId, tag).
// Hosts POST heartbeats every HEARTBEAT_INTERVAL_MS; an instance that misses
// heartbeats for OFFLINE_TIMEOUT_MS is transitioned to offline by the Durable
// Object alarm (an explicit event, not just absence). Everything here is pure
// and synchronous so it unit-tests without Workers runtime or storage.

/** How often hosts should heartbeat. Returned to clients so the cadence is
 * server-owned and can change without shipping new host builds. */
export const HEARTBEAT_INTERVAL_MS = 15_000;

/** Missed-heartbeat window before an instance is declared offline. 3x the
 * heartbeat interval: one lost packet or a slow request never flaps a healthy
 * host offline, while a dead host is declared offline within 45-60s, which
 * matches the "is my Mac reachable right now" freshness a phone needs. */
export const OFFLINE_TIMEOUT_MS = 45_000;

/** Offline records older than this are pruned from the presence map. The
 * durable device identity lives in the Aurora `devices` registry; presence
 * only keeps enough offline history to render "last seen 2h ago" for recently
 * active instances. */
export const PRUNE_AFTER_MS = 24 * 60 * 60 * 1000;

export interface PresenceInstance {
  /** cmux-generated persisted device UUID (same identity as the Aurora
   * `devices.device_uuid` registry column). */
  deviceId: string;
  /** Build tag of the running cmux app instance ("default" for stable). */
  tag: string;
  /** "mac" | "ios" | "linux" | ... free-form, mirrors the registry. */
  platform: string;
  displayName?: string;
  capabilities: string[];
  online: boolean;
  /** Epoch ms of the last heartbeat received. */
  lastSeenAt: number;
  /** Epoch ms when the instance most recently transitioned to online. */
  onlineSince?: number;
  /** Epoch ms when the instance was declared offline (timeout or goodbye). */
  offlineAt?: number;
}

export interface HeartbeatInput {
  deviceId: string;
  tag: string;
  platform: string;
  displayName?: string;
  capabilities?: string[];
  /** True when the host is shutting down cleanly and wants an immediate
   * offline transition instead of waiting out the timeout. */
  stopping?: boolean;
}

export type PresenceEvent =
  | { type: "online"; instance: PresenceInstance }
  | { type: "offline"; instance: PresenceInstance; reason: "timeout" | "goodbye" }
  | { type: "seen"; deviceId: string; tag: string; lastSeenAt: number };

export interface HeartbeatResult {
  instance: PresenceInstance;
  /** Events to broadcast to subscribers, in order. A fresh heartbeat on an
   * already-online instance yields only a lightweight "seen" tick. */
  events: PresenceEvent[];
}

/** Apply one heartbeat to the (possibly absent) existing record. */
export function applyHeartbeat(
  existing: PresenceInstance | undefined,
  beat: HeartbeatInput,
  nowMs: number,
): HeartbeatResult {
  if (beat.stopping) {
    return applyGoodbye(existing, beat, nowMs);
  }
  const wasOnline = existing?.online === true;
  const instance: PresenceInstance = {
    deviceId: beat.deviceId,
    tag: beat.tag,
    platform: beat.platform,
    displayName: beat.displayName ?? existing?.displayName,
    capabilities: beat.capabilities ?? existing?.capabilities ?? [],
    online: true,
    lastSeenAt: nowMs,
    onlineSince: wasOnline ? existing.onlineSince : nowMs,
  };
  const events: PresenceEvent[] = wasOnline
    ? [{ type: "seen", deviceId: instance.deviceId, tag: instance.tag, lastSeenAt: nowMs }]
    : [{ type: "online", instance }];
  return { instance, events };
}

/** Apply a clean-shutdown goodbye: immediate offline transition. */
function applyGoodbye(
  existing: PresenceInstance | undefined,
  beat: HeartbeatInput,
  nowMs: number,
): HeartbeatResult {
  const instance: PresenceInstance = {
    deviceId: beat.deviceId,
    tag: beat.tag,
    platform: beat.platform,
    displayName: beat.displayName ?? existing?.displayName,
    capabilities: beat.capabilities ?? existing?.capabilities ?? [],
    online: false,
    lastSeenAt: existing?.lastSeenAt ?? nowMs,
    onlineSince: undefined,
    offlineAt: nowMs,
  };
  // Only emit an offline event when the instance was actually online; a
  // goodbye from an already-offline (or never-seen) instance is a no-op tick.
  const events: PresenceEvent[] =
    existing?.online === true ? [{ type: "offline", instance, reason: "goodbye" }] : [];
  return { instance, events };
}

/** Devices per team, mirroring the registry's `MAX_DEVICES_PER_TEAM`
 * (`web/app/api/devices/route.ts`). Owner pins are the DO's device records. */
export const MAX_DEVICES_PER_TEAM = 200;

/** App instances (tags) per device, mirroring the registry's
 * `MAX_INSTANCES_PER_DEVICE`. */
export const MAX_INSTANCES_PER_DEVICE = 25;

export type CapCheck =
  | { ok: true }
  | { ok: false; error: "too_many_devices" | "too_many_instances" };

/** Enforce the registry's per-team caps on presence writes.
 *
 * Both `deviceId` and `tag` are client-controlled after auth, so without
 * per-device and per-team bounds one authenticated member could mint
 * unbounded fake devices or tags, bloat every snapshot, and starve the rest
 * of the team out of the caps. Mirroring the registry's limits (200 devices
 * per team, 25 instances per device) also structurally bounds the team's
 * instance map at 200 x 25 = 5000 without a separate aggregate check,
 * because every stored instance's device holds an owner pin. Pure for tests.
 *
 * - `teamDeviceCount` is consulted only when this heartbeat pins a new
 *   device (`isNewDevice`).
 * - `deviceInstanceCount` is consulted only when this heartbeat stores a new
 *   `(deviceId, tag)` record (`isNewInstance`).
 */
export function checkPresenceCaps(input: {
  isNewDevice: boolean;
  teamDeviceCount: number;
  isNewInstance: boolean;
  deviceInstanceCount: number;
}): CapCheck {
  if (input.isNewDevice && input.teamDeviceCount >= MAX_DEVICES_PER_TEAM) {
    return { ok: false, error: "too_many_devices" };
  }
  if (input.isNewInstance && input.deviceInstanceCount >= MAX_INSTANCES_PER_DEVICE) {
    return { ok: false, error: "too_many_instances" };
  }
  return { ok: true };
}

export type OwnerCheck =
  | { ok: true; /** Pin this user as the device owner (first contact). */ pin: boolean }
  | { ok: false; error: "device_owner_mismatch" };

/** Presence mirrors the registry's ownership guard
 * (`web/app/api/devices/route.ts`: a device row pins the registering
 * `userId`, and a different user's write is rejected): the first
 * authenticated user to announce a device owns it, and only that user's
 * heartbeats are accepted afterwards. Without this, any team member could
 * forge a co-member's device online or force it offline with a goodbye, since
 * device ids are visible to the whole team.
 *
 * The pin lives in DO storage and is durable: it is never pruned with the
 * 24h presence tail, so an idle device cannot be re-claimed by a co-member.
 * Known residual (accepted until the registry's planned per-device
 * key-pinning phase, see the `devices` schema note): the very first claim of
 * a deviceId is first-authenticated-writer-wins, because the presence
 * service deliberately has no synchronous dependency on the Aurora registry
 * (presence must stay available when the web API is not) and the registry
 * does not yet issue verifiable device credentials. Blast radius is presence
 * display only; attach routes and durable identity stay registry-owned.
 * Pure for tests. */
export function checkDeviceOwner(
  existingOwner: string | undefined,
  userId: string,
): OwnerCheck {
  if (existingOwner === undefined) return { ok: true, pin: true };
  if (existingOwner === userId) return { ok: true, pin: false };
  return { ok: false, error: "device_owner_mismatch" };
}

export interface ExpiryResult {
  /** Instances flipped to offline, with their updated records. */
  expired: PresenceInstance[];
  events: PresenceEvent[];
}

/** Flip every online instance whose heartbeat deadline has passed to offline.
 * Returns the updated records and the offline events to broadcast. */
export function expireInstances(
  instances: readonly PresenceInstance[],
  nowMs: number,
  timeoutMs: number = OFFLINE_TIMEOUT_MS,
): ExpiryResult {
  const expired: PresenceInstance[] = [];
  const events: PresenceEvent[] = [];
  for (const instance of instances) {
    if (!instance.online) continue;
    if (nowMs - instance.lastSeenAt < timeoutMs) continue;
    const updated: PresenceInstance = {
      ...instance,
      online: false,
      onlineSince: undefined,
      offlineAt: nowMs,
    };
    expired.push(updated);
    events.push({ type: "offline", instance: updated, reason: "timeout" });
  }
  return { expired, events };
}

/** Whether an offline record is old enough to delete entirely. */
export function shouldPrune(
  instance: PresenceInstance,
  nowMs: number,
  pruneAfterMs: number = PRUNE_AFTER_MS,
): boolean {
  if (instance.online) return false;
  const reference = instance.offlineAt ?? instance.lastSeenAt;
  return nowMs - reference >= pruneAfterMs;
}

/** Epoch ms at which the alarm must next fire, or null when nothing is
 * pending. Online instances need an expiry check at lastSeenAt+timeout;
 * offline instances need a prune pass at offlineAt+pruneAfter. */
export function nextAlarmTime(
  instances: readonly PresenceInstance[],
  timeoutMs: number = OFFLINE_TIMEOUT_MS,
  pruneAfterMs: number = PRUNE_AFTER_MS,
): number | null {
  let next: number | null = null;
  for (const instance of instances) {
    const due = instance.online
      ? instance.lastSeenAt + timeoutMs
      : (instance.offlineAt ?? instance.lastSeenAt) + pruneAfterMs;
    if (next === null || due < next) next = due;
  }
  return next;
}

export interface PresenceDevice {
  deviceId: string;
  platform: string;
  displayName?: string;
  /** Online if any instance is online. */
  online: boolean;
  /** Max lastSeenAt over all instances. */
  lastSeenAt: number;
  instances: PresenceInstance[];
}

export interface PresenceSnapshot {
  type: "snapshot";
  teamId: string;
  now: number;
  heartbeatIntervalMs: number;
  offlineTimeoutMs: number;
  devices: PresenceDevice[];
}

/** Roll instance records up into per-device presence for the snapshot the
 * clients render (device online = any instance online). */
export function buildSnapshot(
  teamId: string,
  instances: readonly PresenceInstance[],
  nowMs: number,
): PresenceSnapshot {
  const byDevice = new Map<string, PresenceInstance[]>();
  for (const instance of instances) {
    const list = byDevice.get(instance.deviceId) ?? [];
    list.push(instance);
    byDevice.set(instance.deviceId, list);
  }
  const devices: PresenceDevice[] = [];
  for (const [deviceId, list] of byDevice) {
    list.sort((a, b) => b.lastSeenAt - a.lastSeenAt);
    const newest = list[0];
    if (!newest) continue;
    devices.push({
      deviceId,
      platform: newest.platform,
      displayName: list.find((i) => i.displayName)?.displayName,
      online: list.some((i) => i.online),
      lastSeenAt: newest.lastSeenAt,
      instances: list,
    });
  }
  devices.sort((a, b) => b.lastSeenAt - a.lastSeenAt);
  return {
    type: "snapshot",
    teamId,
    now: nowMs,
    heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
    offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
    devices,
  };
}
