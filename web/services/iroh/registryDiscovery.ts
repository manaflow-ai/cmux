const NATIVE_DISCOVERY_LEASE_MS = 180_000;
const LEGACY_NATIVE_DISCOVERY_LEASE_MS = 24 * 60 * 60 * 1_000;
const NATIVE_DISCOVERY_TOUCH_INTERVAL_MS = 60_000;

type DeviceInstance = {
  routes: unknown[];
  labels?: unknown;
  lastSeenAt?: string | Date;
};
type RegistryDevice = { platform: string; labels: unknown; instances: DeviceInstance[] };

function isMarkedDiscoveryLease(labels: unknown): boolean {
  return labels !== null && typeof labels === "object"
    && !Array.isArray(labels)
    && "discoveryLease" in labels
    && (labels as Record<string, unknown>).discoveryLease === true;
}

/** The top-level protocol opt-in owns the reserved label; unrelated labels survive. */
export function registrationDiscoveryLabels(
  labels: Record<string, unknown>,
  discoveryLease: unknown,
): Record<string, unknown> {
  const { discoveryLease: _ignored, ...otherLabels } = labels;
  void _ignored;
  return discoveryLease === true ? { ...otherLabels, discoveryLease: true } : otherLabels;
}

/** Lease renewals must touch the server timestamp before the short lease expires. */
export function discoveryRegistrationTouchInterval(
  instanceLabels: unknown,
  configuredIntervalMs: number,
): number {
  return isMarkedDiscoveryLease(instanceLabels)
    ? Math.min(configuredIntervalMs, NATIVE_DISCOVERY_TOUCH_INTERVAL_MS)
    : configuredIntervalMs;
}

function instanceIsFresh(instance: DeviceInstance, nowMs: number): boolean {
  const lastSeen = instance.lastSeenAt instanceof Date
    ? instance.lastSeenAt.getTime()
    : typeof instance.lastSeenAt === "string" ? Date.parse(instance.lastSeenAt) : NaN;
  if (!Number.isFinite(lastSeen)) return false;
  const lease = isMarkedDiscoveryLease(instance.labels)
    ? NATIVE_DISCOVERY_LEASE_MS
    : LEGACY_NATIVE_DISCOVERY_LEASE_MS;
  return lastSeen <= nowMs && nowMs - lastSeen < lease;
}

/** Empty-route or expired native instances withdraw from discovery. Manual remotes stay durable. */
export function filterDiscoverableDevices<T extends RegistryDevice>(
  devices: readonly T[],
  now: Date | number = Date.now(),
): T[] {
  const nowMs = now instanceof Date ? now.getTime() : now;
  return devices.flatMap((device) => {
    const manual = device.labels !== null && typeof device.labels === "object"
      && !Array.isArray(device.labels)
      && "manual" in device.labels
      && (device.labels as Record<string, unknown>).manual === true;
    if (device.platform !== "mac" || manual) return [device];
    const instances = device.instances.filter((instance) =>
      instance.routes.length > 0 && instanceIsFresh(instance, nowMs));
    return instances.length === 0 ? [] : [{ ...device, instances }];
  });
}
