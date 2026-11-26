// The stress ladder's judged number (bench/sim-ladder.bench.ts): what one more item costs at the top rung against at the
// middle one. Its own module so a test imports it without running the bench.
/// The per-item cost under which a marginal is noise on a shared runner: both marginals under it read flat (1.0).
export const FLOOR = {
  cpu_ms_per_s: 0.5,
  cpu_window_ms_per_s: 0.5,
  script_ms_per_s: 0.25,
  pss_mb: 0.5,
  heap_mb: 0.5,
} as const;
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

/// How many standard errors either side of a marginal its interval spans (about 95 %).
export const SIGMAS = 2;

/// The two marginals (cost per item over the low span, then over the high span) and their standard errors, from each
/// rung's standard error (the CPU metrics: the spread of a rung's 5 s windows over sqrt(n)).
export function marginals(rungs: number[], values: number[], se: number[]) {
  const [lo, mid, top] = rungs as [number, number, number];
  const [a, b, c] = values as [number, number, number];
  const [ea, eb, ec] = se as [number, number, number];
  return {
    low: (b - a) / (mid - lo),
    high: (c - b) / (top - mid),
    lowSe: Math.hypot(ea, eb) / (mid - lo),
    highSe: Math.hypot(eb, ec) / (top - mid),
  };
}

/// The interval marginalRatio's number sits in when each marginal may lie SIGMAS standard errors either side: the same
/// formula (high / max(low, FLOOR)) at the interval's corners. It never changes the ratio; the bench prints it, with
/// FLOOR, beside the ratio, so a ratio that two noises made reads as one.
export function ratioInterval(metric: keyof typeof FLOOR, rungs: number[], values: number[], se: number[]) {
  const { low, high, lowSe, highSe } = marginals(rungs, values, se);
  const floor = FLOOR[metric];
  const corners = [low - SIGMAS * lowSe, low + SIGMAS * lowSe].flatMap((l) =>
    [high - SIGMAS * highSe, high + SIGMAS * highSe].map((h) => h / Math.max(l, floor)),
  );
  return { lo: Math.min(...corners), hi: Math.max(...corners), low, high, lowSe, highSe, floor };
}
