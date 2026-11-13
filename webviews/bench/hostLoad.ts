// l10n-allow-file: benchmark output, not shipped UI.
// How busy the host is, so a busy runner can't make a timing row regress by accident (Leo, 2026-11-09: "we should
// be able to normalize based off load. and for a lot of situations, load shouldn't even necessarily affect it by
// that much").
//
// The probe spins this process's main thread for SPIN_MS of wall time and reads the CPU time it got
// (process.cpuUsage). On a host with a free core the two match and the contention factor is 1; on a host whose cores
// are all taken by other work the thread waits for its turn, so wall time / CPU time is how much longer any
// CPU-bound step takes than it would on that host idle. It needs no idle reference and no knowledge of the CPU, and
// a host with spare cores (most of the time) gives 1, so the rows are left as measured.
//
// bench/web-ui-suite.ts probes right before and right after each bench, while none of the bench's own processes run,
// so the factor is the other work on the host, not the app's own cost: an app that burns more CPU is not normalized
// away. It divides the bench's wall-clock rows (unit ms) by that factor; counts, shifts, scores, MB and ratios are not
// times, and CPU rows (clock "cpu": idle CPU, task ms per second) are work done, not time waited, so they stay as
// measured.
import type { PerfRow } from "./perfRow";

const SPIN_MS = 20;
const SPINS = 9;
/// A factor past this says the probe itself was starved, not a measurement to scale by.
export const MAX_FACTOR = 8;

/// One spin: wall time / CPU time this process got during it (>= 1 on any host, up to rounding).
export function spinRatio(spinMs = SPIN_MS): number {
  const cpu = process.cpuUsage();
  const start = performance.now();
  let sink = 0;
  while (performance.now() - start < spinMs) sink += Math.sqrt(sink + 1);
  const wall = performance.now() - start;
  const used = process.cpuUsage(cpu);
  const cpuMs = (used.user + used.system) / 1000;
  if (sink < 0) console.log(sink); // keep the loop from being optimized away
  return cpuMs > 0 ? wall / cpuMs : MAX_FACTOR;
}

/// The median of `spins` spins back to back (one spin can land on a timer tick or a GC).
export function probe(spins = SPINS): number[] {
  return Array.from({ length: spins }, () => spinRatio());
}

/// The factor to divide a wall-clock row by (pure): the median spin ratio, at least 1 (a process's other threads
/// can make CPU time a little over wall time) and at most MAX_FACTOR, to 2 decimals.
export function contentionFactor(ratios: readonly number[]): number {
  const finite = ratios.filter(Number.isFinite).sort((a, b) => a - b);
  if (!finite.length) return 1;
  const mid = finite.length >> 1;
  const median = finite.length % 2 ? finite[mid]! : (finite[mid - 1]! + finite[mid]!) / 2;
  return Math.round(Math.min(MAX_FACTOR, Math.max(1, median)) * 100) / 100;
}

/// A bench's rows on an idle host's scale (pure): each wall-clock row (unit ms and clock "wall", the defaults) divided by the factor,
/// with the measured p95 kept as raw_p95 and the factor as load. Every other row, and every row at factor 1, is
/// returned as it is.
export function normalizeRows(rows: readonly PerfRow[], factor: number): PerfRow[] {
  if (!(factor > 1)) return [...rows];
  const scale = (value: number) => Math.round((value / factor) * 1_000_000) / 1_000_000;
  return rows.map((row) =>
    (row.unit ?? "ms") !== "ms" || row.clock === "cpu"
      ? row
      : {
          ...row,
          p95: scale(row.p95),
          ...(row.p50 === undefined ? {} : { p50: scale(row.p50) }),
          raw_p95: row.p95,
          load: factor,
        },
  );
}
