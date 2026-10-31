/** The cached one-minute host reading acpmux keeps on each peer. */
export type MachineResources = {
  ramFreeGB: number;
  coresBusy: number;
  cores: number;
  busy: boolean;
  lowMemory: boolean;
};

type RecordValue = Record<string, unknown>;

function record(value: unknown): RecordValue | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as RecordValue) : undefined;
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

/**
 * Parses the bounded health fields retained by the native `_acpmux/status` reply shape. The
 * daemon's pressure verdict carries the host-budget thresholds, so this page does not duplicate
 * or poll those thresholds itself.
 */
export function peerResourcesFromStatus(status: unknown): Record<string, MachineResources> {
  const peers = record(status)?.peers;
  if (!Array.isArray(peers)) return {};
  const resources: Record<string, MachineResources> = {};
  for (const peer of peers) {
    const row = record(peer);
    const name = row?.name;
    const health = record(row?.health);
    const ram = record(health?.ram);
    const pressure = record(health?.pressure);
    if (typeof name !== "string" || !name || !health || health.unsupported === true || !ram || !pressure) continue;
    const freeBytes = finiteNumber(ram.freeBytes);
    const load = Array.isArray(health.load) ? finiteNumber(health.load[0]) : undefined;
    const cores = finiteNumber(pressure.cores) ?? finiteNumber(health.cpus);
    if (freeBytes === undefined || load === undefined || cores === undefined || cores < 1) continue;
    const over = Array.isArray(pressure.over)
      ? pressure.over.filter((reason): reason is string => typeof reason === "string")
      : [];
    resources[name] = {
      ramFreeGB: Math.round((freeBytes / 1e9) * 10) / 10,
      coresBusy: Math.round(load),
      cores: Math.round(cores),
      busy: load >= (finiteNumber(pressure.load_limit) ?? cores),
      // The verdict already applies the machine’s configured RAM threshold (including zero).
      lowMemory: over.some((reason) => reason.startsWith("available RAM ")),
    };
  }
  return resources;
}

export type MachineLoadWarning = { kind: "load"; busy: number; cores: number } | { kind: "memory"; freeGB: number };

/** Returns the first warning shown in a computer row, or nothing when the row is quiet. */
export function machineLoadWarning(
  resources: MachineResources | undefined,
  enabled = true,
): MachineLoadWarning | undefined {
  if (!enabled || !resources) return undefined;
  if (resources.busy) return { kind: "load", busy: resources.coresBusy, cores: resources.cores };
  if (resources.lowMemory) return { kind: "memory", freeGB: resources.ramFreeGB };
  return undefined;
}
