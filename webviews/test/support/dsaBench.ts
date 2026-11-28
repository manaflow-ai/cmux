// l10n-allow-file: test output, not shipped UI.
// Fast, fail-open-proof checks for a data structure or algorithm change: a seeded property test (the old slow
// implementation as the oracle against the new one on random inputs) and a budgeted timing at realistic scale whose
// judged numbers hold up on a loaded shared runner:
//   - `speedup`: old and new timed in ONE process on the same input, interleaved, so runner load cancels out;
//   - `growth`: the new implementation at n and at 10 n, so "flat when the input grows 10x" is a ratio, not a wall time;
//   - an absolute p95 budget, set with headroom for a 32-wide shard, that only catches a gross regression.
// Every timed check prints one `dsa-bench` line (name, n, p50/p95 ms, the ratio) so a run's log is its before -> after.
// No dependency: fast-check is not in webviews' lockfile and adding one reruns every webviews test, so the generator
// here is a seeded PRNG and a failing case names its seed for a one-line replay.
import { expect } from "bun:test";

/// mulberry32: a small, fast, seedable PRNG with a good enough spread for generating test inputs.
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export type Gen = {
  next: () => number;
  int: (lo: number, hi: number) => number;
  pick: <T>(items: readonly T[]) => T;
  bool: (p?: number) => boolean;
};

export function gen(seed: number): Gen {
  const next = rng(seed);
  return {
    next,
    int: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)),
    pick: (items) => items[Math.floor(next() * items.length)] as never,
    bool: (p = 0.5) => next() < p,
  };
}

/// Runs `check` on `runs` seeds (DSA_SEED=N replays one); a throw names the seed that failed.
export function forSeeds(runs: number, check: (g: Gen, seed: number) => void): void {
  const fixed = process.env.DSA_SEED;
  const seeds = fixed ? [Number(fixed)] : Array.from({ length: runs }, (_, i) => 0x9e3779b1 ^ (i * 2654435761));
  for (const seed of seeds) {
    try {
      check(gen(seed), seed);
    } catch (error) {
      throw new Error(`property failed at DSA_SEED=${seed >>> 0}: ${(error as Error).message}`, { cause: error });
    }
  }
}

export type Timing = { p50: number; p95: number; samples: number[] };

const quantile = (sorted: number[], q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;

function timing(samples: number[]): Timing {
  const sorted = [...samples].sort((a, b) => a - b);
  return { p50: quantile(sorted, 0.5), p95: quantile(sorted, 0.95), samples };
}

/// Times `run` `runs` times after `warmup` untimed calls. `run` may return a value; it is kept so the work is not dead.
export function measure(run: () => unknown, runs = 15, warmup = 3): Timing {
  let sink: unknown;
  for (let i = 0; i < warmup; i++) sink = run();
  const samples: number[] = [];
  for (let i = 0; i < runs; i++) {
    const start = performance.now();
    sink = run();
    samples.push(performance.now() - start);
  }
  (globalThis as { __dsaSink?: unknown }).__dsaSink = sink;
  return timing(samples);
}

const ms = (value: number) => (value < 0.1 ? value.toFixed(4) : value.toFixed(2));

function report(line: Record<string, string | number>) {
  console.log(
    `dsa-bench ${Object.entries(line)
      .map(([k, v]) => `${k}=${v}`)
      .join(" ")}`,
  );
}

/// Old and new on the same input, interleaved run by run so load on the runner hits both alike. Asserts the new one is
/// at least `minSpeedup` times faster at p50 and under `budgetMs` at p95; prints the before -> after line.
export function expectSpeedup(
  name: string,
  n: number,
  old: () => unknown,
  next: () => unknown,
  { minSpeedup, budgetMs, runs = 9 }: { minSpeedup: number; budgetMs: number; runs?: number },
): { before: Timing; after: Timing; speedup: number } {
  old();
  next();
  const a: number[] = [];
  const b: number[] = [];
  for (let i = 0; i < runs; i++) {
    a.push(measure(old, 1, 0).p50);
    b.push(measure(next, 1, 0).p50);
  }
  const before = timing(a);
  const after = timing(b);
  const speedup = before.p50 / Math.max(after.p50, 1e-6);
  report({
    name,
    n,
    before_p50_ms: ms(before.p50),
    before_p95_ms: ms(before.p95),
    after_p50_ms: ms(after.p50),
    after_p95_ms: ms(after.p95),
    speedup: speedup.toFixed(1),
  });
  expect(after.p95).toBeLessThan(budgetMs);
  expect(speedup).toBeGreaterThanOrEqual(minSpeedup);
  return { before, after, speedup };
}

/// The new implementation at n and at 10 n: the p50 ratio must stay under `maxRatio` (flat: ~1; linear: ~10). Both
/// under `floorMs` reads flat, since timer and GC noise dominates there.
export function expectGrowth(
  name: string,
  n: number,
  at: (n: number) => () => unknown,
  { maxRatio, floorMs = 0.05, runs = 15 }: { maxRatio: number; floorMs?: number; runs?: number },
): number {
  const small = measure(at(n), runs);
  const large = measure(at(n * 10), runs);
  const ratio = large.p50 <= floorMs && small.p50 <= floorMs ? 1 : large.p50 / Math.max(small.p50, floorMs);
  report({
    name,
    n,
    p50_ms: ms(small.p50),
    p50_10x_ms: ms(large.p50),
    p95_10x_ms: ms(large.p95),
    ratio_10x: ratio.toFixed(2),
  });
  expect(ratio).toBeLessThan(maxRatio);
  return ratio;
}
