// l10n-allow-file: benchmark output, not shipped UI.
// The shared web UI perf harness: runs the web UI benches with short, CI-sized arguments, collects
// their PERF_ROW lines (bench/perfRow.ts), prints them slowest first relative to their target, and
// prints one JSON report as its last line: {"rows": [...], "benches": {...}, "failed": [...]}.
// The perf cron (scripts/cmux-next/perf-cron.py, part "web-ui") runs it on a Linux runner and judges
// the rows; it is advisory, on the cron only, never on a push or pull request path.
// A bench that exits non-zero, times out or prints no row is listed in `failed` (never a silent pass);
// the suite exits 1 only when no bench printed a row.
//   bun bench/web-ui-suite.ts [--only chat-open,chat-switch] [--out report.json]
// The browser benches need Playwright's chromium and webkit (playwright install --with-deps --only-shell
// chromium webkit) and build the pane themselves.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { PERF_ROW_MARK, type PerfRow } from "./perfRow";

type Bench = { name: string; file: string; args: string[]; env?: Record<string, string>; timeoutMs: number };

/// Short arguments; the timeouts sum to 25 minutes, under perf-cron.py's 30-minute cap on the suite.
/// Not here: thread-minimap-frame-cost (an A/B check of the VS Code Minimap against its own 1 ms budget,
/// which exits non-zero by design when over it; its rail frame cost is covered by thread-rail-jump),
/// diff-stream (the diff-viewer part already runs it) and thread-rail-drag (an adapter, not a bench).
export const BENCHES: readonly Bench[] = [
  { name: "agent-activity-groups", file: "agent-activity-groups.bench.ts", args: ["5", "50"], timeoutMs: 120_000 },
  { name: "edit-turns-stream", file: "edit-turns-stream.bench.ts", args: ["5", "100"], timeoutMs: 120_000 },
  {
    name: "transcript-view-rows",
    file: "transcript-view-rows.bench.ts",
    args: ["500", "500", "3"],
    timeoutMs: 120_000,
  },
  { name: "chat-open", file: "chat-open.bench.ts", args: ["3", "300"], timeoutMs: 300_000 },
  { name: "chat-switch", file: "chat-switch.bench.ts", args: ["3", "300"], timeoutMs: 300_000 },
  {
    name: "transcript-scroll-frame",
    file: "transcript-scroll-frame.bench.ts",
    args: ["3000", "2"],
    timeoutMs: 240_000,
  },
  { name: "thread-rail-jump", file: "thread-rail-jump.bench.ts", args: ["1000", "5"], timeoutMs: 300_000 },
];

export type Failure = { bench: string; why: string; tail: string[] };

/// The rows in a bench's stdout (pure). A malformed PERF_ROW line is a failure of that bench, not a row.
export function parseRows(stdout: string): { rows: PerfRow[]; bad: string[] } {
  const rows: PerfRow[] = [];
  const bad: string[] = [];
  for (const line of stdout.split("\n")) {
    if (!line.startsWith(PERF_ROW_MARK)) continue;
    try {
      const row = JSON.parse(line.slice(PERF_ROW_MARK.length)) as PerfRow;
      if (typeof row.name === "string" && Number.isFinite(row.p95)) rows.push(row);
      else bad.push(line);
    } catch {
      bad.push(line);
    }
  }
  return { rows, bad };
}

/// Slowest first (pure): rows with a target by p95 / target, highest first, then rows without one by p95.
export function slowestFirst(rows: readonly PerfRow[]): PerfRow[] {
  const ratio = (row: PerfRow) => (row.target ? row.p95 / row.target : -1);
  return [...rows].sort((a, b) => ratio(b) - ratio(a) || b.p95 - a.p95);
}

async function run(bench: Bench) {
  const webviews = path.resolve(import.meta.dir, "..");
  const started = performance.now();
  const proc = Bun.spawn(["bun", path.join("bench", bench.file), ...bench.args], {
    cwd: webviews,
    env: { ...process.env, ...bench.env },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill("SIGKILL");
  }, bench.timeoutMs);
  const [stdout, stderr, exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  return { stdout, stderr, exit, timedOut, seconds: Math.round((performance.now() - started) / 1000) };
}

async function main() {
  const argv = process.argv.slice(2);
  const flag = (name: string) => {
    const at = argv.indexOf(name);
    return at >= 0 ? argv[at + 1] : undefined;
  };
  const only = flag("--only")?.split(",");
  const unknown = only?.filter((name) => !BENCHES.some((bench) => bench.name === name)) ?? [];
  if (unknown.length) {
    console.error(`web-ui-suite: unknown bench ${unknown.join(", ")}`);
    process.exit(2);
  }
  const rows: PerfRow[] = [];
  const failed: Failure[] = [];
  const benches: Record<string, { exit: number | null; seconds: number; rows: number }> = {};
  for (const bench of BENCHES.filter((each) => !only || only.includes(each.name))) {
    console.log(`web-ui-suite: ${bench.name} ${bench.args.join(" ")}`);
    const result = await run(bench);
    const { rows: got, bad } = parseRows(result.stdout);
    // The bench's own human output stays readable in the log.
    for (const line of result.stdout.split("\n"))
      if (line && !line.startsWith(PERF_ROW_MARK)) console.log(`  ${bench.name}| ${line}`);
    benches[bench.name] = { exit: result.exit, seconds: result.seconds, rows: got.length };
    const why = result.timedOut
      ? `timed out after ${bench.timeoutMs / 1000} s`
      : result.exit !== 0
        ? `exit ${result.exit}`
        : got.length === 0
          ? "printed no PERF_ROW"
          : bad.length
            ? `${bad.length} malformed PERF_ROW line(s)`
            : null;
    if (why) {
      const tail = [...bad, ...result.stderr.split("\n").filter(Boolean)].slice(-12);
      failed.push({ bench: bench.name, why, tail });
      console.log(`web-ui-suite: ${bench.name} FAILED (${why})`);
      for (const line of tail) console.log(`  ${bench.name}! ${line}`);
    }
    // A failed bench's rows still count: a timeout after the first arm keeps that arm's numbers.
    rows.push(...got);
  }
  const sorted = slowestFirst(rows);
  console.log("web-ui-suite: slowest first (p95 / target)");
  for (const row of sorted)
    console.log(
      `  ${row.target ? `${((row.p95 / row.target) * 100).toFixed(0).padStart(4)} %` : "     -"}  ${row.name}  ` +
        `p95 ${row.p95} ${row.unit ?? "ms"}${row.target ? ` (target ${row.target})` : ""}`,
    );
  const report = { rows: sorted, benches, failed };
  const out = flag("--out");
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 1));
  console.log(JSON.stringify(report));
  process.exit(rows.length ? 0 : 1);
}

if (import.meta.main) await main();
