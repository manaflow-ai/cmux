// The stress ladder's judged number (bench/sim-ladder.bench.ts): what one more item costs at the top rung against at the
// middle one. Its own module so a test imports it without running the bench.
/// The per-item cost under which a marginal is noise on a shared runner: both marginals under it read flat (1.0).
export const FLOOR = { cpu_ms_per_s: 0.5, script_ms_per_s: 0.25, pss_mb: 0.5 } as const;
const FRAME_FLOOR_MS = 16.7;
export type Metric = keyof typeof FLOOR | "frame_p95_ms";
export type Sample = Record<Metric, number>;

/// The marginal ratio of one metric over three rungs (pure; exported for the test).
export function marginalRatio(metric: Metric, rungs: number[], values: number[]): number {
  const [lo, mid, top] = rungs as [number, number, number];
  const [a, b, c] = values as [number, number, number];
  if (metric === "frame_p95_ms") return c / Math.max(b, FRAME_FLOOR_MS);
  const floor = FLOOR[metric];
  const low = (b - a) / (mid - lo);
  const high = (c - b) / (top - mid);
  if (Math.abs(low) < floor && Math.abs(high) < floor) return 1;
  return high / Math.max(low, floor);
}
