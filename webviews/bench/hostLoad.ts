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

// How fast the host is, which the spin above cannot see: a shared runner whose neighbours fill the memory bus or the
// cache gives this process all the CPU time it asks for (factor 1) and still runs the same code 1.2x to 2.6x slower
// (cmux#24569: rows of code no commit touched moved +58 % to +71 % between two runs). The canary is a fixed piece of
// work, the same in every commit, timed right before and right after each bench: a walk over a table far larger
// than any cache (memory-bound) and a build, sort, group and JSON round trip of small objects (allocation- and
// compute-bound). bench/web-ui-suite.ts stamps the bench's time rows with the canary's ms (`speed`), and the perf
// cron judges a row only against values measured at about that speed: no one factor fits every row (the same slow
// host cost one row 1.17x and another 1.9x), so a row from an off-speed host is not scaled, it is not judged.
// On the shared runner the walk is what tells the hosts apart (2026-11-16, 4 runners): 4.4 to 5.1 ms on two of them
// and 33 to 41 ms on the other two, whose pure benches ran 1.2x to 1.4x slower; the work half moved 1.18x.
const WALK_CELLS = 1 << 23; // 32 MB of Uint32
const WALK_STEPS = 300_000;
const WORK_ITEMS = 3000;
const SPEED_SAMPLES = 3;
let walkTable: Uint32Array | undefined;

/// A full-period LCG over the table's cells: every step lands on a cell the caches have not seen.
function table(): Uint32Array {
  if (walkTable) return walkTable;
  walkTable = new Uint32Array(WALK_CELLS);
  for (let i = 0; i < WALK_CELLS; i += 1) walkTable[i] = (Math.imul(i, 1664525) + 1013904223) & (WALK_CELLS - 1);
  return walkTable;
}

function walk(): number {
  const cells = table();
  let at = 0;
  for (let step = 0; step < WALK_STEPS; step += 1) at = cells[at]!;
  return at;
}

function work(): number {
  const items = Array.from({ length: WORK_ITEMS }, (_, i) => ({
    id: `item-${(Math.imul(i, 2654435761) >>> 0) % 100003}`,
    group: i % 17,
    at: (i * 7919) % 10007,
  }));
  items.sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1));
  const groups = new Map<number, typeof items>();
  for (const item of items) {
    const group = groups.get(item.group);
    if (group) group.push(item);
    else groups.set(item.group, [item]);
  }
  return (JSON.parse(JSON.stringify([...groups.values()])) as unknown[]).length;
}

const fastestOf = (reps: number, fn: () => number): number => {
  let best = Number.POSITIVE_INFINITY;
  let sink = 0;
  for (let rep = 0; rep < reps; rep += 1) {
    const start = performance.now();
    sink += fn();
    best = Math.min(best, performance.now() - start);
  }
  if (sink < 0) console.log(sink);
  return best;
};

/// One canary sample: the ms its two halves took, each the fastest of 3 (a rep can land on a GC or lose its core).
export function speedSample(): { walk: number; work: number } {
  return { walk: fastestOf(3, walk), work: fastestOf(3, work) };
}

/// `samples` canary samples back to back, after one unmeasured sample that builds the table and warms the JIT.
export function speedProbe(samples = SPEED_SAMPLES): { walk: number; work: number }[] {
  if (!walkTable) speedSample();
  return Array.from({ length: samples }, speedSample);
}

/// The host's speed while a bench ran (pure): the median canary sample's walk + work ms, to 3 decimals; 0 with no
/// sample (not known).
export function hostSpeed(samples: readonly { walk: number; work: number }[]): number {
  const totals = samples.map((each) => each.walk + each.work).filter((ms) => Number.isFinite(ms) && ms > 0);
  if (!totals.length) return 0;
  totals.sort((a, b) => a - b);
  const mid = totals.length >> 1;
  return Math.round((totals.length % 2 ? totals[mid]! : (totals[mid - 1]! + totals[mid]!) / 2) * 1000) / 1000;
}

/// A bench's rows with the host's speed on each time row (pure; unit ms, wall and CPU alike: a slower host takes
/// more CPU time for the same work too). Counts, scores and sizes do not depend on it, and speed 0 is not known.
export function stampSpeed(rows: readonly PerfRow[], speed: number): PerfRow[] {
  if (!(speed > 0)) return [...rows];
  return rows.map((row) => ((row.unit ?? "ms") === "ms" ? { ...row, speed } : row));
}

// bun bench/hostLoad.ts: this host's load and speed now.
if (import.meta.main) {
  const samples = speedProbe();
  const mid = (values: number[]) => [...values].sort((a, b) => a - b)[values.length >> 1]!;
  console.log(
    JSON.stringify({
      load: contentionFactor(probe()),
      speed: hostSpeed(samples),
      walk: Math.round(mid(samples.map((each) => each.walk)) * 1000) / 1000,
      work: Math.round(mid(samples.map((each) => each.work)) * 1000) / 1000,
    }),
  );
}
