import type { VMStats } from "./drivers/types";

export const VM_RESOURCE_USAGE_KEY = "cmuxResourceUsage";
export const VM_RESOURCE_USAGE_MAX_AGE_MS = 90_000;
export const VM_RESOURCE_USAGE_MIN_INTERVAL_MS = 15_000;

export type VmResourceUsage = Pick<VMStats, "cpuPercent" | "memoryUsedMb" | "diskUsedMb">;

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

/** Whitelist gauges only; a guest cannot claim identity, timestamps, or capacity. */
export function parseVmResourceUsage(value: unknown): VmResourceUsage | null {
  const input = record(value);
  if (!input) return null;
  const result: { cpuPercent?: number; memoryUsedMb?: number; diskUsedMb?: number } = {};
  for (const key of ["cpuPercent", "memoryUsedMb", "diskUsedMb"] as const) {
    const number = input[key];
    if (number === undefined) continue;
    if (typeof number !== "number" || !Number.isFinite(number) || number < 0) return null;
    if (key === "cpuPercent" ? number > 100 : !Number.isSafeInteger(number)) return null;
    result[key] = number;
  }
  return Object.keys(result).length ? result : null;
}

/** The provider owns state and dimensions. Only a fresh sample from this guest supplies usage. */
export function applyVmResourceUsage(
  stats: VMStats,
  metadata: Readonly<Record<string, unknown>>,
  providerVmId: string,
  now: number,
): VMStats {
  if (stats.state !== "awake") return stats;
  const sample = record(metadata[VM_RESOURCE_USAGE_KEY]);
  if (!sample || sample.providerVmId !== providerVmId) return stats;
  const receivedAt = sample.receivedAt;
  if (typeof receivedAt !== "number" || !Number.isFinite(receivedAt)
    || receivedAt > now || now - receivedAt > VM_RESOURCE_USAGE_MAX_AGE_MS) return stats;
  const usage = parseVmResourceUsage(sample);
  return usage ? { ...stats, ...usage, sampledAt: receivedAt } : stats;
}
