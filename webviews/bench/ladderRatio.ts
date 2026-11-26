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

/// A cumulative reading (renderer CPU ms, ScriptDuration s) at time t, linear between the two samples around it; past
/// either end, the end sample. `times` ascending.
export function interpolate(times: number[], values: number[], t: number): number {
  if (!times.length) return 0;
  if (t <= times[0]!) return values[0]!;
  for (let i = 1; i < times.length; i += 1) {
    if (t <= times[i]!) {
      const span = times[i]! - times[i - 1]!;
      const f = span > 0 ? (t - times[i - 1]!) / span : 1;
      return values[i - 1]! + f * (values[i]! - values[i - 1]!);
    }
  }
  return values[values.length - 1]!;
}

/// A rate over whole collection cycles. The chats share one V8 heap, whose major collection costs CPU in step with the
/// heap (x10 at 190 MB about 1.3 s, x50 at 830 MB about 5.9 s) and comes every 8-20 s: a fixed window holds one or two
/// of them by phase, so its reading swings by a collection over the window. From the end of one major collection to
/// the end of a later one is a whole number of cycles (each cycle's marking, its pause and the sweeping after), so the
/// reading counts every collection once, at the heap's own rate.
///   bounds  the major collections' end times, ascending (the same clock as `times`)
///   times, values  a cumulative reading's samples (CPU ms, script ms), ascending in time
/// Returns the rate (value per unit of time) over bounds[0] .. bounds[last], the cycles it spans, and its standard
/// error: the jackknife of the ratio of sums over the cycles (each cycle left out in turn), null under two cycles.
export function cycleRate(bounds: number[], times: number[], values: number[]) {
  const at = bounds.map((t) => interpolate(times, values, t));
  const cycles = bounds.length - 1;
  if (cycles < 1) return null;
  const cost = Array.from({ length: cycles }, (_, i) => at[i + 1]! - at[i]!);
  const span = Array.from({ length: cycles }, (_, i) => bounds[i + 1]! - bounds[i]!);
  const sumCost = cost.reduce((a, b) => a + b, 0);
  const sumSpan = span.reduce((a, b) => a + b, 0);
  const rate = sumCost / sumSpan;
  let se: number | null = null;
  if (cycles >= 2) {
    const loo = cost.map((c, i) => (sumCost - c) / (sumSpan - span[i]!));
    const mean = loo.reduce((a, b) => a + b, 0) / cycles;
    se = Math.sqrt(((cycles - 1) / cycles) * loo.reduce((a, b) => a + (b - mean) ** 2, 0));
  }
  return { rate, se, cycles, span: sumSpan, perCycle: cost.map((c, i) => c / span[i]!) };
}

/// Where the cycles of a run end: at each major collection episode's end, and, when the run stopped (`end`) before
/// `want` cycles closed, at the run's end too. A cap cuts off the long cycles and keeps the short ones, so closed cycles
/// alone read high; the open tail counts as one more cycle whose collection has not come yet (one collection short).
export function cycleBounds(ends: number[], end: number, want: number) {
  const capped = ends.length > 0 && ends.length < want + 1 && end > ends[ends.length - 1]!;
  return { bounds: capped ? [...ends, end] : ends, capped };
}

/// Two major collections less than this apart (microseconds) are one episode, and a cycle ends at the episode's last:
/// V8 often follows a collection with another within a second (chats x10: ends at 6.1 and 6.8 s), and a 0.7 s "cycle"
/// between them, read alone, is all collection (1194 ms/s against 77 for the next). The span between episodes still
/// holds every collection; only where a cycle may end moves.
export const EPISODE_GAP_US = 3_000_000;

/// The end times of one isolate's major collection episodes from trace events (MajorGC, `ts`/`dur` in microseconds):
/// the isolate is the one whose collections saw the largest heap (the chats' shared one). Collections that start less
/// than `gapUs` after the previous one ended join its episode.
export function majorGcEnds(
  events: { pid: number; ts: number; dur: number; heapBefore: number }[],
  gapUs = EPISODE_GAP_US,
) {
  if (!events.length) return { pid: null as number | null, ends: [] as number[] };
  const pid = [...events].sort((a, b) => b.heapBefore - a.heapBefore)[0]!.pid;
  const mine = events.filter((e) => e.pid === pid).sort((a, b) => a.ts - b.ts);
  const ends: number[] = [];
  for (const e of mine) {
    const end = e.ts + e.dur;
    if (ends.length && e.ts - ends[ends.length - 1]! < gapUs)
      ends[ends.length - 1] = Math.max(ends[ends.length - 1]!, end);
    else ends.push(end);
  }
  return { pid, ends };
}
