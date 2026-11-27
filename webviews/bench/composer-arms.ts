// l10n-allow-file: benchmark output, not shipped UI.
// A/B arms for a page bench: two (or more) webviews source trees measured in one invocation, interleaved, with a
// noise floor. A bench gives it a `run(port)` that measures one fresh page on the arm served at `port` and returns
// its row; this module builds and serves each arm, runs the schedule and prints the summary.
//
//   --arms A=DIR,B=DIR   each DIR a webviews directory, relative to webviews/ (`.` is this one; another is a copy
//                        beside it with its own src, node_modules a symlink to this one's). Each arm is built once
//                        (vite build of its vite.config.acpmux-pane.mjs, or its dev server with --dev) and served on
//                        its own port.
//   --rounds N           rounds per case (default 6). A round runs the arms in order, then reversed: A B B A.
//   --no-floor           drop the noise floor. With it, a third arm A' (the first arm again, same build) runs in every
//                        round, A B A' A' B A, and every other round swaps A and A' (A' B A A B A') so both hold the
//                        same places: A' against A is two identical arms measured in the same run.
//
// The bench's `run` must start a fresh browser process and page per call, so no arm inherits another's heap, caches
// or JIT state. The summary gives per arm the median, [interquartile range] and (min-max) over its runs of each named
// metric, then each arm's median minus the first arm's, marked `sep` where the two interquartile ranges do not overlap.
// A host that slows down mid-run moves whole rounds (every arm alike, which the interleave cancels), so read the
// medians and IQRs, not min-max.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type Arm = { name: string; dir: string };
export type ArmRun = Record<string, unknown> & { arm: string; round: number };
type Stats = { median: number; q1: number; q3: number; min: number; max: number };

/// The arms `--arms` names, or none (the bench then runs this checkout alone, as before).
export function parseArms(value: string | undefined, webviews: string): Arm[] | undefined {
  if (!value) return undefined;
  return value.split(",").map((entry) => {
    const at = entry.indexOf("=");
    if (at <= 0) throw new Error(`--arms: ${entry} is not NAME=DIR`);
    const dir = path.resolve(webviews, entry.slice(at + 1));
    if (!fs.existsSync(path.join(dir, "vite.config.acpmux-pane.mjs")))
      throw new Error(`--arms: ${dir} is not a webviews directory (no vite.config.acpmux-pane.mjs)`);
    return { name: entry.slice(0, at), dir };
  });
}

/// Serves the agent pane of the webviews tree at `dir` and returns its port: a vite build served as files (as it
/// ships: production React, the React Compiler pass; unminified with `unminified`, so a profile names functions),
/// or with `dev` the tree's vite dev server. `releases` gets what to stop afterwards.
export async function servePane(
  dir: string,
  options: { dev?: boolean; unminified?: boolean; sourcemap?: boolean; built?: (out: string) => void },
  releases: (() => unknown)[],
): Promise<number> {
  const configFile = path.join(dir, "vite.config.acpmux-pane.mjs");
  if (options.dev) {
    const { createServer } = await import("vite");
    const { warmViteServer } = await import("../test/support/warmDevServer");
    const vite = await createServer({
      configFile,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    releases.push(() => vite.close());
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    return (vite.httpServer!.address() as { port: number }).port;
  }
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-typing-bench-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile,
    build: {
      outDir: out,
      emptyOutDir: true,
      ...(options.unminified ? { minify: false } : {}),
      ...(options.sourcemap ? { sourcemap: true } : {}),
    },
    logLevel: "error",
  });
  options.built?.(out);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  return statics.port!;
}

/// The run order: per round the arms then reversed (A B B A); with the floor arm A' last, every other round swaps
/// A and A'.
export function armSchedule<T extends { name: string }>(arms: T[], rounds: number, floor: boolean) {
  const order = [...arms, ...[...arms].reverse()];
  const first = arms[0]!;
  const last = arms.at(-1)!;
  const swapped = order.map((arm) => (!floor ? arm : arm === first ? last : arm === last ? first : arm));
  const schedule: { arm: T; round: number }[] = [];
  for (let round = 1; round <= rounds; round += 1)
    for (const arm of round % 2 ? order : swapped) schedule.push({ arm, round });
  return schedule;
}

/// Builds and serves every arm, then runs one case (`label`) through the schedule: `run(port)` per slot, a line per
/// run, and the summary of `metrics` at the end. Returns every run's row with its arm and round.
export async function runArms(options: {
  arms: Arm[];
  rounds: number;
  floor: boolean;
  label: string;
  metrics: readonly string[];
  ports: Map<string, number>;
  run: (port: number) => Promise<Record<string, unknown>>;
}): Promise<ArmRun[]> {
  const { arms, rounds, floor, label, metrics, ports, run } = options;
  const served = arms.map((arm) => ({ name: arm.name, port: ports.get(arm.name)! }));
  if (floor) served.push({ name: `${served[0]!.name}'`, port: served[0]!.port });
  const runs: ArmRun[] = [];
  for (const { arm, round } of armSchedule(served, rounds, floor)) {
    const row: ArmRun = { arm: arm.name, round, ...(await run(arm.port)) };
    runs.push(row);
    console.log(`RUN ${label} round ${round} ${arm.name}: ${metrics.map((m) => `${m} ${String(row[m])}`).join(", ")}`);
  }
  printArms(
    label,
    runs,
    served.map((arm) => arm.name),
    metrics,
    floor,
  );
  return runs;
}

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length / 2;
  return sorted.length % 2 ? sorted[Math.floor(mid)]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};
const quantile = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]!;
};
const r1 = (value: number) => Math.round(value * 10) / 10;
const statsOf = (list: number[]): Stats => ({
  median: r1(median(list)),
  q1: r1(quantile(list, 0.25)),
  q3: r1(quantile(list, 0.75)),
  min: r1(Math.min(...list)),
  max: r1(Math.max(...list)),
});

/// Per metric a row: each arm's median [IQR] (min-max), then each later arm's median minus the first's (`sep`
/// where the IQRs do not overlap). With the floor, the last arm is the first again: its column is the noise floor.
export function printArms(label: string, runs: ArmRun[], names: string[], metrics: readonly string[], floor: boolean) {
  const values = (arm: string, metric: string) =>
    runs
      .filter((run) => run.arm === arm)
      .map((run) => Number(run[metric] ?? Number.NaN))
      .filter(Number.isFinite);
  const [first, ...rest] = names;
  const table: Record<string, Record<string, string>> = {};
  const summary: Record<string, Record<string, Stats>> = {};
  for (const metric of metrics) {
    const row: Record<string, string> = {};
    const base = values(first!, metric);
    for (const arm of names) {
      const list = values(arm, metric);
      if (!list.length) continue;
      const stats = statsOf(list);
      (summary[arm] ??= {})[metric] = stats;
      row[arm] = `${stats.median} [${stats.q1}-${stats.q3}] (${stats.min}-${stats.max})`;
    }
    for (const arm of rest) {
      const list = values(arm, metric);
      if (!list.length || !base.length) continue;
      const a = statsOf(base);
      const b = statsOf(list);
      const diff = r1(b.median - a.median);
      row[`${arm}-${first}`] = `${diff > 0 ? "+" : ""}${diff}${b.q1 > a.q3 || b.q3 < a.q1 ? " sep" : ""}`;
    }
    table[metric] = row;
  }
  const perArm = Math.max(...names.map((arm) => runs.filter((run) => run.arm === arm).length));
  console.log(
    `ARMS ${label}, ${perArm} runs per arm (median [IQR] (min-max) over runs)` +
      (floor ? `; noise floor: ${first}' against ${first}` : ""),
  );
  console.table(table);
  console.log(`BENCH-ARMS ${JSON.stringify({ label, arms: names, summary })}`);
}
