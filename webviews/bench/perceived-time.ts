// l10n-allow-file: benchmark output, not shipped UI.
// Perceived time, judged per pull request (Leo, 2026-11-23: "just perceived time to visible/settled and percieved
// interactive time"). Three numbers for each key UI state, each from navigation start or from the input that asked
// for the state, as a person feels them:
//   visible      the state's newest content is painted (what the person came for is on screen);
//   settled      nothing moved for 400 ms after that: no long task, no layout shift, the scroller still;
//   interactive  the first input the state takes is accepted and echoed on screen.
// A state with no row for one of them says so (null), never a stand-in number.
//
// The rows come from the benches that already measure them (PERF_ROW lines, bench/perfRow.ts); this file only names
// which row is which number. The gate runs each state's bench in two trees, the pull request's base and its head, on one
// runner, interleaved base, head, head, base, and pools each arm's rounds. A number regresses when the head's median is
// over the base's by more than both RATIO and the state's floor and the head's lower quartile is over the base's
// median too (most head rounds are slower, not one). A suspected regression measures that state once more (another
// base, head, head, base) and is judged on all of its rounds, so one noisy block never fails a pull request.
//
//   bun bench/perceived-time.ts --base BASE_TREE --head HEAD_TREE [--out DIR] [--only chat_open] [--body PR_BODY_FILE]
//
// Exit 0: no regression (or the description carries `perceived-time: <reason>`); 1: a confirmed regression; 2: the
// head printed no row for a number it must have (a harness failure is never a pass). Writes DIR/perceived-time.json
// and DIR/perceived-time.md, appends the table to $GITHUB_STEP_SUMMARY, and prints the head's numbers as PERF_ROW
// lines named perceived.<state>.<number> (the record of each pull request, in its run's log and artifact).
// The perf cron (scripts/cmux-next/perf-cron.py) keeps measuring the same rows on feat-cmux-next's tip; this is the
// pull request side of it.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { PERF_ROW_MARK, type PerfRow } from "./perfRow";

export type Metric = "visible" | "settled" | "interactive";
export const METRICS: readonly Metric[] = ["visible", "settled", "interactive"];

export type PerceivedState = {
  /// Stable, the PERF_ROW name's middle part: perceived.<state>.<metric>.
  state: string;
  /// What a person does to reach it, for the table.
  what: string;
  bench: string;
  args: string[];
  env?: Record<string, string>;
  timeoutMs: number;
  /// The bench's row for each number, or null when no bench measures it yet.
  rows: Record<Metric, string | null>;
  /// The change in ms under which a difference is runner noise for this state.
  floorMs: number;
};

/// Over by more than this share of the base's median (and the floor) before a number can regress.
export const RATIO = 0.15;

export const STATES: readonly PerceivedState[] = [
  {
    state: "chat_open",
    what: "Open an agent chat cold (300 turns): fresh page, no cache",
    bench: "chat-open.bench.ts",
    args: ["5", "300"],
    env: { COMPOSER: "1" },
    timeoutMs: 240_000,
    rows: {
      visible: "chat_open.compact.latest",
      settled: "chat_open.compact.settled",
      interactive: "chat_open.compact.composer_interactive",
    },
    floorMs: 40,
  },
  {
    state: "chat_switch",
    what: "Switch to an unread agent chat (300 turns)",
    bench: "chat-switch.bench.ts",
    args: ["3", "300"],
    timeoutMs: 420_000,
    rows: {
      visible: "chat_switch.unread.latest",
      settled: "chat_switch.unread.settled",
      // The switch bench types nothing after the switch; no row measures a key after a switch yet.
      interactive: null,
    },
    floorMs: 25,
  },
];

export const WAIVER = /^\s*perceived-time:\s*\S.*$/im;

export function median(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  if (!sorted.length) return Number.NaN;
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// The value at quantile q (0..1), linear between the two nearest ranks (pure).
export function quantile(values: readonly number[], q: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  if (!sorted.length) return Number.NaN;
  const at = (sorted.length - 1) * q;
  const lo = Math.floor(at);
  const hi = Math.ceil(at);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (at - lo);
}

/// The rows in a bench's stdout (pure); a malformed line is skipped (the head then lacks the row and fails as 2).
export function parseRows(stdout: string): PerfRow[] {
  const rows: PerfRow[] = [];
  for (const line of stdout.split("\n")) {
    if (!line.startsWith(PERF_ROW_MARK)) continue;
    try {
      const row = JSON.parse(line.slice(PERF_ROW_MARK.length)) as PerfRow;
      if (typeof row.name === "string" && Number.isFinite(row.p95)) rows.push(row);
    } catch {
      // not a row
    }
  }
  return rows;
}

/// A row's rounds: its `samples` when the bench gave them, else its median as one value (an older base's bench).
export function roundsOf(row: PerfRow): number[] {
  const samples = row.samples?.filter(Number.isFinite);
  if (samples?.length) return samples;
  return [row.p50 ?? row.p95];
}

export type Judgement = {
  metric: Metric;
  row: string | null;
  base: number[];
  head: number[];
  baseMedian: number | null;
  headMedian: number | null;
  deltaMs: number | null;
  verdict: "pass" | "regressed" | "faster" | "no row" | "no base" | "head missing" | "unmeasured";
};

/// One number's verdict from both arms' pooled rounds (pure).
export function judge(
  metric: Metric,
  row: string | null,
  base: readonly number[],
  head: readonly number[],
  floorMs: number,
  ratio = RATIO,
): Judgement {
  const out = { metric, row, base: [...base], head: [...head], baseMedian: null, headMedian: null, deltaMs: null };
  if (row === null) return { ...out, verdict: "no row" };
  // Neither tree printed the row: the bench is broken at base (or on this runner), not by this change.
  if (!head.length && !base.length) return { ...out, verdict: "unmeasured" };
  if (!head.length) return { ...out, verdict: "head missing" };
  const headMedian = median(head);
  if (!base.length) return { ...out, headMedian, verdict: "no base" };
  const baseMedian = median(base);
  const deltaMs = headMedian - baseMedian;
  const bound = Math.max(ratio * baseMedian, floorMs);
  const regressed = deltaMs > bound && quantile(head, 0.25) > baseMedian;
  const faster = -deltaMs > bound && quantile(head, 0.75) < baseMedian;
  return {
    ...out,
    baseMedian,
    headMedian,
    deltaMs,
    verdict: regressed ? "regressed" : faster ? "faster" : "pass",
  };
}

type Arm = "base" | "head";
type Pool = Record<Arm, Map<string, number[]>>;

async function runBench(tree: string, state: PerceivedState): Promise<{ rows: PerfRow[]; note?: string }> {
  const webviews = path.join(tree, "webviews");
  if (!fs.existsSync(path.join(webviews, "bench", state.bench))) return { rows: [], note: `no bench/${state.bench}` };
  const proc = Bun.spawn(["bun", path.join("bench", state.bench), ...state.args], {
    cwd: webviews,
    env: { ...process.env, ...state.env },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  const timer = setTimeout(() => proc.kill("SIGKILL"), state.timeoutMs);
  const [stdout, stderr, exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  const rows = parseRows(stdout);
  if (exit !== 0 || !rows.length) {
    const tail = [...stdout.split("\n").slice(-6), ...stderr.split("\n").slice(-10)].filter((l) => l.trim());
    return { rows, note: `exit ${exit}: ${tail.join(" | ").slice(-1200)}` };
  }
  return { rows };
}

/// One block: base, head, head, base, each arm's rounds added to the pool.
async function block(trees: Record<Arm, string>, state: PerceivedState, pool: Pool, notes: string[]) {
  for (const arm of ["base", "head", "head", "base"] as const) {
    const started = performance.now();
    const { rows, note } = await runBench(trees[arm], state);
    const seconds = Math.round((performance.now() - started) / 1000);
    console.log(`perceived-time: ${state.state} ${arm} ${seconds}s ${rows.length} rows${note ? ` (${note})` : ""}`);
    if (note) notes.push(`${state.state} ${arm}: ${note}`);
    for (const row of rows) {
      const kept = pool[arm].get(row.name) ?? [];
      kept.push(...roundsOf(row));
      pool[arm].set(row.name, kept);
    }
  }
}

function judgeState(state: PerceivedState, pool: Pool): Judgement[] {
  return METRICS.map((metric) => {
    const row = state.rows[metric];
    return judge(
      metric,
      row,
      row ? (pool.base.get(row) ?? []) : [],
      row ? (pool.head.get(row) ?? []) : [],
      state.floorMs,
    );
  });
}

const ms = (value: number | null) => (value === null ? "–" : `${value.toFixed(0)} ms`);

/// The table for the run page and the artifact (pure).
export function markdown(
  results: { state: PerceivedState; judgements: Judgement[]; blocks: number }[],
  head: string,
  base: string,
  waived: boolean,
): string {
  const lines = [
    "## Perceived time: visible, settled, interactive",
    "",
    `Head \`${head.slice(0, 12)}\` against base \`${base.slice(0, 12)}\`, one runner, base and head interleaved; medians of every round.` +
      ` A number regresses past ${RATIO * 100}% and the state's floor, with most head rounds over the base's median.`,
    "",
    "| State | Number | Row | Base | Head | Change | Rounds (base/head) | Verdict |",
    "|---|---|---|---|---|---|---|---|",
  ];
  for (const { state, judgements } of results)
    for (const j of judgements)
      lines.push(
        `| ${state.what} | ${j.metric} | ${j.row ? `\`${j.row}\`` : "not measured yet"} | ${ms(j.baseMedian)} | ${ms(j.headMedian)} | ${
          j.deltaMs === null ? "–" : `${j.deltaMs >= 0 ? "+" : ""}${j.deltaMs.toFixed(0)} ms`
        } | ${j.base.length}/${j.head.length} | ${j.verdict === "regressed" ? "**regressed**" : j.verdict} |`,
      );
  const regressed = results.some((r) => r.judgements.some((j) => j.verdict === "regressed"));
  lines.push("");
  if (regressed)
    lines.push(
      waived
        ? "A number regressed; the description's `perceived-time:` line accepts it."
        : "A number regressed. Fix it, or add a line `perceived-time: <why this is worth it>` to the description and rerun this job.",
    );
  return `${lines.join("\n")}\n`;
}

async function main() {
  const argv = process.argv.slice(2);
  const flag = (name: string) => {
    const at = argv.indexOf(name);
    return at >= 0 ? argv[at + 1] : undefined;
  };
  const base = flag("--base");
  const head = flag("--head");
  if (!base || !head) {
    console.error(
      "usage: bun bench/perceived-time.ts --base TREE --head TREE [--out DIR] [--only STATE,...] [--body FILE]",
    );
    process.exit(2);
  }
  const out = path.resolve(flag("--out") ?? ".");
  fs.mkdirSync(out, { recursive: true });
  const only = flag("--only")?.split(",");
  const bodyFile = flag("--body");
  const waived = bodyFile && fs.existsSync(bodyFile) ? WAIVER.test(fs.readFileSync(bodyFile, "utf8")) : false;
  const sha = (tree: string) =>
    Bun.spawnSync(["git", "-C", tree, "rev-parse", "HEAD"]).stdout.toString().trim() || path.basename(tree);
  const trees = { base: path.resolve(base), head: path.resolve(head) };
  const notes: string[] = [];
  const results: { state: PerceivedState; judgements: Judgement[]; blocks: number }[] = [];
  for (const state of STATES.filter((s) => !only || only.includes(s.state))) {
    const pool: Pool = { base: new Map(), head: new Map() };
    await block(trees, state, pool, notes);
    let blocks = 1;
    let judgements = judgeState(state, pool);
    if (judgements.some((j) => j.verdict === "regressed")) {
      console.log(`perceived-time: ${state.state} looks slower; measuring it once more before judging`);
      await block(trees, state, pool, notes);
      blocks = 2;
      judgements = judgeState(state, pool);
    }
    results.push({ state, judgements, blocks });
  }
  for (const { state, judgements } of results)
    for (const j of judgements)
      if (j.headMedian !== null)
        console.log(
          PERF_ROW_MARK +
            JSON.stringify({
              name: `perceived.${state.state}.${j.metric}`,
              p50: j.headMedian,
              p95: j.headMedian,
              unit: "ms",
              samples: j.head,
            }),
        );
  const table = markdown(results, sha(trees.head), sha(trees.base), waived);
  console.log(table);
  if (notes.length) console.log(`notes:\n${notes.join("\n")}`);
  fs.writeFileSync(path.join(out, "perceived-time.md"), table);
  fs.writeFileSync(
    path.join(out, "perceived-time.json"),
    `${JSON.stringify({ schema: 1, head: sha(trees.head), base: sha(trees.base), ratio: RATIO, waived, notes, results: results.map((r) => ({ state: r.state.state, what: r.state.what, floorMs: r.state.floorMs, blocks: r.blocks, numbers: r.judgements })) }, null, 1)}\n`,
  );
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, table);
  const all = results.flatMap((r) => r.judgements);
  if (all.some((j) => j.verdict === "head missing")) {
    console.error("perceived-time: the head printed no row for a number it measures; see notes");
    process.exit(2);
  }
  if (all.some((j) => j.verdict === "unmeasured"))
    console.log("::warning title=perceived time::a bench printed no row in base or head; see the notes in the summary");
  if (all.some((j) => j.verdict === "regressed") && !waived) process.exit(1);
}

if (import.meta.main) await main();
