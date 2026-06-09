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
