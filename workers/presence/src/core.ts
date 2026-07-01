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

/** One attach route as the registry stores it (`device_app_instances.routes`
 * jsonb). Opaque to presence, exactly like the registry route: bounded plain
 * objects whose semantic schema (`CmxAttachRoute`) is owned by the clients, so
 * new route kinds flow through without a worker ship. */
export type PresenceRoute = Record<string, unknown>;

export interface PresenceInstance {
  /** cmux-generated persisted device UUID (same identity as the Aurora
   * `devices.device_uuid` registry column). */
  deviceId: string;
  /** Build tag of the running cmux app instance ("default" for stable). */
  tag: string;
  /** "mac" | "ios" | "linux" | ... free-form, mirrors the registry. */
  platform: string;
  displayName?: string;
  /** The app's bundle id, so clients can label the build channel (Stable /
   * Nightly / RC / DEV). Absent for older hosts that don't report it. */
  bundleId?: string;
  capabilities: string[];
  online: boolean;
  /** Epoch ms of the last heartbeat received. */
  lastSeenAt: number;
  /** Epoch ms when the instance most recently transitioned to online. */
  onlineSince?: number;
  /** Epoch ms when the instance was declared offline (timeout or goodbye). */
  offlineAt?: number;
  /** The instance's current attach routes, mirrored from the host's heartbeat.
   * A live CACHE of the durable registry row (the host writes the same set to
   * `POST /api/devices`), kept here so subscribers get fresh routes pushed in
   * realtime instead of polling the registry. Reconciliation on DO cold start
   * is the heartbeat itself: hosts re-announce the full set within 15s. */
  routes?: PresenceRoute[];
}

export interface HeartbeatInput {
  deviceId: string;
  tag: string;
  platform: string;
  displayName?: string;
  bundleId?: string;
  capabilities?: string[];
  /** True when the host is shutting down cleanly and wants an immediate
   * offline transition instead of waiting out the timeout. */
  stopping?: boolean;
  /** Current attach routes. Absent means "unchanged" (the previous set is
   * kept); an empty array means "no routes" (e.g. pairing turned off). */
  routes?: PresenceRoute[];
}

export type PresenceEvent =
  | { type: "online"; instance: PresenceInstance }
  | { type: "offline"; instance: PresenceInstance; reason: "timeout" | "goodbye" }
  | { type: "seen"; deviceId: string; tag: string; lastSeenAt: number }
  /** The instance's attach routes changed while online (new port/IP). Carries
   * the full updated instance so subscribers can reconnect on the fresh routes
   * without a registry round trip. */
  | { type: "routes"; instance: PresenceInstance };

export interface HeartbeatResult {
  instance: PresenceInstance;
  /** Events to broadcast to subscribers, in order. A fresh heartbeat on an
   * already-online instance yields only a lightweight "seen" tick. */
  events: PresenceEvent[];
}

/** Whether two route sets are the same, order-sensitively (hosts publish a
 * priority-ordered list, so order is meaning). Routes are small bounded JSON
 * objects, so canonical-enough comparison via JSON.stringify is fine: a false
 * "changed" only costs one extra push. Pure for tests. */
export function routesEqual(
  a: readonly PresenceRoute[] | undefined,
  b: readonly PresenceRoute[] | undefined,
): boolean {
  if (a === undefined || b === undefined) return a === b;
  if (a.length !== b.length) return false;
  return JSON.stringify(a) === JSON.stringify(b);
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
  // Absent routes mean "unchanged": keep the previous set so a client that
  // omits the field (or a future slim keepalive) never wipes pushed routes.
  const routes = beat.routes ?? existing?.routes;
  const instance: PresenceInstance = {
    deviceId: beat.deviceId,
    tag: beat.tag,
    platform: beat.platform,
    displayName: beat.displayName ?? existing?.displayName,
    bundleId: beat.bundleId ?? existing?.bundleId,
    capabilities: beat.capabilities ?? existing?.capabilities ?? [],
    online: true,
    lastSeenAt: nowMs,
    onlineSince: wasOnline ? existing.onlineSince : nowMs,
    ...(routes !== undefined ? { routes } : {}),
  };
  if (!wasOnline) {
    return { instance, events: [{ type: "online", instance }] };
  }
  // Already online: a changed route set is the realtime "new port/IP" push;
  // an unchanged one is just a lightweight liveness tick.
  const events: PresenceEvent[] =
    beat.routes !== undefined && !routesEqual(existing.routes, beat.routes)
      ? [{ type: "routes", instance }]
      : [{ type: "seen", deviceId: instance.deviceId, tag: instance.tag, lastSeenAt: nowMs }];
  return { instance, events };
}

/** Apply a clean-shutdown goodbye: immediate offline transition. */
function applyGoodbye(
  existing: PresenceInstance | undefined,
  beat: HeartbeatInput,
  nowMs: number,
): HeartbeatResult {
  // Keep the last known routes on the offline record: they are the
  // best-known rendezvous for "try waking this host", matching the registry
  // row that outlives the instance going offline.
  const routes = beat.routes ?? existing?.routes;
  const instance: PresenceInstance = {
    deviceId: beat.deviceId,
    tag: beat.tag,
    platform: beat.platform,
    displayName: beat.displayName ?? existing?.displayName,
    bundleId: beat.bundleId ?? existing?.bundleId,
    capabilities: beat.capabilities ?? existing?.capabilities ?? [],
    online: false,
    lastSeenAt: existing?.lastSeenAt ?? nowMs,
    onlineSince: undefined,
    offlineAt: nowMs,
    ...(routes !== undefined ? { routes } : {}),
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

/** Resolve the subscribe-stream deadline the worker forwarded
 * (`x-presence-expires-at`, computed from the verified token's expiry).
 *
 * Returns the effective deadline, defensively re-capped at `nowMs + maxAgeMs`,
 * or `null` when the subscription must be rejected: a missing/garbled header
 * (the worker always sets it, so absence means the request did not come
 * through the worker path intact) or a deadline already in the past (the
 * token was valid at verification but expired before the DO handled the
 * forwarded request). A past deadline must never be replaced with a fresh
 * window, or an expired token could open a stream for another `maxAgeMs`.
 * Pure for tests. */
export function resolveSubscribeDeadline(
  header: string | null,
  nowMs: number,
  maxAgeMs: number,
): number | null {
  const value = Number(header);
  if (header === null || header === "" || !Number.isFinite(value)) return null;
  if (value <= nowMs) return null;
  return Math.min(value, nowMs + maxAgeMs);
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
