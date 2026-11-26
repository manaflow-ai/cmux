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
/// How many standard errors a marginal, or the growth from one marginal to the next, must clear to count as measured.
export const SIGMAS = 2;

/// The two marginals (cost per item over the low span, then over the high span) and, when each rung's reading carries a
/// standard error, how far the growth between them must go before it is measured rather than noise.
export function marginals(rungs: number[], values: number[], se?: number[]) {
  const [lo, mid, top] = rungs as [number, number, number];
  const [a, b, c] = values as [number, number, number];
  const [ea, eb, ec] = (se ?? [0, 0, 0]) as [number, number, number];
  const d1 = mid - lo;
  const d2 = top - mid;
  const low = (b - a) / d1;
  const high = (c - b) / d2;
  // high - low = c/d2 - b(1/d1 + 1/d2) + a/d1: the middle rung's reading is in both marginals.
  const growthSe = Math.sqrt((ec / d2) ** 2 + (eb * (1 / d1 + 1 / d2)) ** 2 + (ea / d1) ** 2);
  return { low, high, lowSe: Math.hypot(ea, eb) / d1, highSe: Math.hypot(eb, ec) / d2, growthSe };
}

/// The marginal ratio of one metric over three rungs (pure; exported for the test).
/// se, when given, is each rung's standard error (the CPU metrics: the spread of a rung's 5 s windows over sqrt(n)). Then
///   - a marginal under SIGMAS of its own standard error is no denominator: the low one is divided by
///     max(low, FLOOR, SIGMAS x its error), so a low span that read 0 +- 1 ms/s per item cannot turn noise above into 5x;
///   - growth (high - low) under SIGMAS of its standard error is not measured, and the ratio reads at most 1.0: the
///     readings do not show one more item costing more at the top. The bench prints that bound with every ratio
///     (sim_ladder.AXIS.METRIC.resolution), so a run too noisy to see growth says so instead of passing quietly.
/// Without se it is the plain rule: both marginals under FLOOR read flat, else high / max(low, FLOOR).
export function marginalRatio(metric: Metric, rungs: number[], values: number[], se?: number[]): number {
  if (metric === "frame_p95_ms") return values[2]! / Math.max(values[1]!, FRAME_FLOOR_MS);
  const { low, high, lowSe, highSe, growthSe } = marginals(rungs, values, se);
  const floor = FLOOR[metric];
  const lowFloor = Math.max(floor, SIGMAS * lowSe);
  const highFloor = Math.max(floor, SIGMAS * highSe);
  if (Math.abs(low) < lowFloor && Math.abs(high) < highFloor) return 1;
  const ratio = high / Math.max(low, lowFloor);
  if (se && high - low <= SIGMAS * growthSe) return Math.min(1, ratio);
  return ratio;
}
