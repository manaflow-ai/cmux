// l10n-allow-file: benchmark output, not shipped UI.
// The shared web UI perf harness: runs the web UI benches with short, CI-sized arguments, collects
// their PERF_ROW lines (bench/perfRow.ts), prints them slowest first relative to their target, and
// prints one JSON report as its last line: {"rows": [...], "benches": {...}, "failed": [...]}.
// The perf cron (scripts/cmux-next/perf-cron.py, part "web-ui") runs it on a Linux runner and judges
// the rows; it is advisory, on the cron only, never on a push or pull request path.
// A bench that exits non-zero, times out or prints no row is listed in `failed` (never a silent pass);
// the suite exits 1 only when no bench printed a row.
// A busy runner can't make a timing row regress by accident: the suite probes the host's CPU contention right
// before and after each bench (bench/hostLoad.ts) and divides that bench's ms rows by it (1 on a host with a free
// core, so most runs keep their rows as measured). Each bench's factor is in the report's `benches`.
//   bun bench/web-ui-suite.ts [--only chat-open,chat-switch] [--out report.json]
// The browser benches need Playwright's chromium and webkit (playwright install --with-deps --only-shell
// chromium webkit) and build the pane themselves.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { contentionFactor, normalizeRows, probe } from "./hostLoad";
import { PERF_ROW_MARK, type PerfRow } from "./perfRow";

/// `ownPart`: run only when `--only` names it (perf-cron.py gives it a part of its own, outside the 30-minute cap).
type Bench = {
  name: string;
  file: string;
  args: string[];
  env?: Record<string, string>;
  timeoutMs: number;
  ownPart?: boolean;
};

/// Short arguments; the timeouts of the benches without `ownPart` sum to 29.5 minutes, under perf-cron.py's 30-minute cap on the suite.
/// Not here: thread-minimap-frame-cost (an A/B check of the VS Code Minimap against its own 1 ms budget,
/// which exits non-zero by design when over it; its rail frame cost is covered by thread-rail-jump),
/// diff-stream (the diff-viewer part already runs it) and thread-rail-drag (an adapter, not a bench).
export const BENCHES: readonly Bench[] = [
  {
    name: "agent-activity-groups",
    file: "agent-activity-groups.bench.ts",
    args: ["5", "50"],
    timeoutMs: 120_000,
  },
  {
    name: "edit-turns-stream",
    file: "edit-turns-stream.bench.ts",
    args: ["5", "100"],
    timeoutMs: 120_000,
  },
  {
    name: "transcript-view-rows",
    file: "transcript-view-rows.bench.ts",
    args: ["500", "500", "3"],
    timeoutMs: 120_000,
  },
  // chat-open takes about 18 s on the perf runner (2026-11-08); 165 s leaves the suite's sum where it was.
  { name: "chat-open", file: "chat-open.bench.ts", args: ["3", "300"], timeoutMs: 165_000 },
  { name: "chat-switch", file: "chat-switch.bench.ts", args: ["3", "300"], timeoutMs: 255_000 },
  {
    name: "transcript-scroll-frame",
    file: "transcript-scroll-frame.bench.ts",
    args: ["3000", "2"],
    timeoutMs: 240_000,
  },
  {
    name: "thread-rail-jump",
    file: "thread-rail-jump.bench.ts",
    args: ["1000", "5"],
    timeoutMs: 150_000,
  },
  { name: "ui-stability", file: "ui-stability.bench.ts", args: ["2"], timeoutMs: 240_000 },
  // A turn that ends while the reader is scrolled up: CLS, the anchor's drift and rows folded away.
  {
    name: "transcript-turn-end-shift",
    file: "transcript-turn-end-shift.bench.ts",
    args: ["2"],
    timeoutMs: 120_000,
  },
  // Recorded and generated acpmux logs played into the pane at top speed: shift on open and while streaming, work per
  // token as rows grow (its slope), long tasks, heap and idle CPU.
  {
    name: "transcript-replay",
    file: "transcript-replay.bench.ts",
    args: ["--turns", "600"],
    timeoutMs: 150_000,
  },
  // 50 tool calls landing in a running turn on the wall clock, as an agent sends them: frame gaps, long tasks, a
  // record's arrival to its paint, task ms per call and layout shift.
  {
    name: "tool-call-burst",
    file: "tool-call-burst.bench.ts",
    args: ["--rounds", "3"],
    timeoutMs: 120_000,
  },
  // 500 chats on the History page and 500 live chats (one per workspace) on the New Tab page: scroll frame work,
  // React per frame, mount and a row's press to its paint.
  {
    name: "all-chats-list",
    file: "all-chats-list.bench.ts",
    args: ["3", "500"],
    timeoutMs: 90_000,
  },
  // One session's status, unread, title or cost changing at 100, 1,000 and 3,000 listed sessions: the cost per change
  // and its growth, which should be none. perf-cron.py's web-ui-scale part (about 90 s on a lane VM).
  {
    name: "update-one",
    file: "update-one.bench.ts",
    args: ["--changes", "20", "--turns", "1000"],
    timeoutMs: 300_000,
    ownPart: true,
  },
  // The pane's state layer kept per operation that should keep nothing (sessions made and closed, chats reopened,
  // reconnects mid-stream, a shell's output streaming), small and god side by side: bytes, objects and entries per
  // operation after warm-up (bench/stateGrowth.ts). perf-cron.py's web-ui-growth part runs it (`--only state-growth`).
  {
    name: "state-growth",
    file: "state-growth.bench.ts",
    args: ["120", "--scale", "both"],
    timeoutMs: 240_000,
    ownPart: true,
  },
  // The same clock tick and 30-row list update drawn by an app (scene ops) and by the first-party component:
  // main-thread ms and React commits per update. Run with `--only extension-parity`.
  {
    name: "extension-parity",
    file: "extension-parity.bench.ts",
    args: ["3", "200"],
    timeoutMs: 180_000,
    ownPart: true,
  },
  // The same benches on the god session (bench/godFixture.ts: tens of thousands of rows, MB tool outputs, nested
  // subagents, images, months of history). Their rows carry `god` after the prefix (chat_open.god.compact.latest),
  // so each pairs with its ordinary row; perf-cron.py runs them as a part of their own (web-ui-god), beside the
  // ordinary three: the six timeouts sum to 1,710 s, under that part's 1,800 s cap (about 13 minutes measured).
  {
    name: "chat-open-god",
    file: "chat-open.bench.ts",
    args: ["3", "300"],
    env: { FIXTURE: "god" },
    timeoutMs: 300_000,
    ownPart: true,
  },
  {
    name: "chat-switch-god",
    file: "chat-switch.bench.ts",
    args: ["3", "300"],
    env: { FIXTURE: "god" },
    timeoutMs: 420_000,
    ownPart: true,
  },
  {
    name: "transcript-replay-god",
    file: "transcript-replay.bench.ts",
    args: [],
    env: { FIXTURE: "god" },
    timeoutMs: 420_000,
    ownPart: true,
  },
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

/// How far over its target a row is (pure): p95 / target; a row with a target of 0 (a count or a shift that should
/// be none) is infinitely over when above it and at 0 when on it; -1 for a row without a target.
export function overTarget(row: PerfRow): number {
  if (row.target === undefined) return -1;
  if (row.target === 0) return row.p95 > 0 ? Number.POSITIVE_INFINITY : 0;
  return row.p95 / row.target;
}

/// Slowest first (pure): rows with a target by p95 / target, highest first, then rows without one by p95.
export function slowestFirst(rows: readonly PerfRow[]): PerfRow[] {
  return [...rows].sort((a, b) => {
    const [ra, rb] = [overTarget(a), overTarget(b)];
    return (ra === rb ? 0 : rb > ra ? 1 : -1) || b.p95 - a.p95;
  });
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
  return {
    stdout,
    stderr,
    exit,
    timedOut,
    seconds: Math.round((performance.now() - started) / 1000),
  };
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
  const benches: Record<string, { exit: number | null; seconds: number; rows: number; load: number }> = {};
  for (const bench of BENCHES.filter((each) => (only ? only.includes(each.name) : !each.ownPart))) {
    console.log(`web-ui-suite: ${bench.name} ${bench.args.join(" ")}`);
    const before = probe();
    const result = await run(bench);
    const load = contentionFactor([...before, ...probe()]);
    const { rows: measured, bad } = parseRows(result.stdout);
    const got = normalizeRows(measured, load);
    if (load > 1) console.log(`web-ui-suite: ${bench.name} ran on a busy host: its ms rows are divided by ${load}`);
    // The bench's own human output stays readable in the log.
    for (const line of result.stdout.split("\n"))
      if (line && !line.startsWith(PERF_ROW_MARK)) console.log(`  ${bench.name}| ${line}`);
    benches[bench.name] = { exit: result.exit, seconds: result.seconds, rows: got.length, load };
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
      `  ${row.target === undefined ? "     -" : overTarget(row) === Number.POSITIVE_INFINITY ? "  over" : `${(overTarget(row) * 100).toFixed(0).padStart(4)} %`}  ${row.name}  ` +
        `p95 ${row.p95} ${row.unit ?? "ms"}${row.target === undefined ? "" : ` (target ${row.target})`}`,
    );
  const report = { rows: sorted, benches, failed };
  const out = flag("--out");
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 1));
  console.log(JSON.stringify(report));
  process.exit(rows.length ? 0 : 1);
}

if (import.meta.main) await main();
