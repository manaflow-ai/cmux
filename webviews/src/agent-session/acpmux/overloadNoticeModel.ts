/// What acpmux says about this Mac's load and swap (`_acpmux/host_overload`, host_overload.rs):
/// Rust reads the host and applies the thresholds (load average over 5 per core, swap over 80%);
/// this only reads the answer.
export type HostOverload = {
  overloaded: boolean;
  load1?: number;
  cores: number;
  swapPercent?: number;
  loadOver: boolean;
  swapOver: boolean;
};

export function readHostOverload(value: unknown): HostOverload | undefined {
  if (!value || typeof value !== "object") return undefined;
  const v = value as Record<string, unknown>;
  if (typeof v.overloaded !== "boolean" || typeof v.cores !== "number") return undefined;
  const num = (n: unknown) => (typeof n === "number" && Number.isFinite(n) ? n : undefined);
  const load1 = num(v.load1);
  const swapPercent = num(v.swapPercent);
  return {
    overloaded: v.overloaded,
    cores: v.cores,
    loadOver: v.loadOver === true,
    swapOver: v.swapOver === true,
    ...(load1 !== undefined && { load1 }),
    ...(swapPercent !== undefined && { swapPercent }),
  };
}

/// How often the pane asks. acpmux reuses a reading for 15 s, so this costs one small request.
export const OVERLOAD_POLL_MS = 30_000;
