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
// The browser benches need Playwright's webkit (playwright install --with-deps webkit) and Chrome
// (scripts/ci/ensure-system-chrome.sh; bench/browsers.ts launches it) and build the pane themselves.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { contentionFactor, normalizeRows, probe } from "./hostLoad";
import { PERF_ROW_MARK, type PerfRow } from "./perfRow";
import { SHARED_BUILD_ENV, sharedBuildDir, sharedPageKey } from "./support/sharedBuilds";

/// A build the suite makes once per run for the benches that name it (bench/support/sharedBuilds.ts): the agent
/// pane, the gallery, or one serveBenchPage page (`page:/test/browser/x.html`, the tree's vite.config.ts).
export type SharedBuild = "pane" | "gallery" | `page:${string}`;

/// `ownPart`: run only when `--only` names it (perf-cron.py gives it a part of its own, outside the 30-minute cap).
/// `builds`: the builds it takes from the suite instead of building them inside its own timeout.
type Bench = {
  name: string;
  file: string;
  args: string[];
  env?: Record<string, string>;
  timeoutMs: number;
  ownPart?: boolean;
  builds?: readonly SharedBuild[];
};

/// Short arguments; the timeouts of the benches without `ownPart`, with SHARED_BUILDS_CAP_MS for the builds the suite
/// makes once before them, sum to at most SUITE_CAP_MS (49.5 minutes), under perf-cron.py's 50-minute cap on the suite
/// (test/web-ui-suite-order.test.ts holds them to it). A bench's timeout covers its measuring, not a cold build. Each timeout is about 1.5x
/// or more of what its bench takes on the perf cron's runner (blacksmith-4vcpu), which runs these benches about 1.7x as
/// long as a fast-checks runner does (the base's ui-stability failed its Chromium launch after 57-59 s there, 30-34 s on
/// fast-checks runs 43373098960 and 43374947921).
/// Not here: thread-minimap-frame-cost (an A/B check of the VS Code Minimap against its own 1 ms budget,
/// which exits non-zero by design when over it; its rail frame cost is covered by thread-rail-jump),
/// diff-stream (the diff-viewer part already runs it) and thread-rail-drag (an adapter, not a bench).
export const BENCHES: readonly Bench[] = [
  // These three take 0 to 2 s on the perf runner (2026-11-12).
  {
    name: "agent-activity-groups",
    file: "agent-activity-groups.bench.ts",
    args: ["5", "50"],
    timeoutMs: 30_000,
  },
  {
    name: "edit-turns-stream",
    file: "edit-turns-stream.bench.ts",
    args: ["5", "100"],
    timeoutMs: 30_000,
  },
  {
    name: "transcript-view-rows",
    file: "transcript-view-rows.bench.ts",
    args: ["500", "500", "3"],
    timeoutMs: 30_000,
  },
  // chat-open takes about 36 s on the perf runner (2026-11-12).
  { name: "chat-open", file: "chat-open.bench.ts", args: ["3", "300"], timeoutMs: 105_000, builds: ["pane"] },
  { name: "chat-switch", file: "chat-switch.bench.ts", args: ["3", "300"], timeoutMs: 255_000, builds: ["pane"] },
  // settled_page.score_max (NOW settled_page_score_max, cmuxterm-hq goals/settled-page-ceiling.md). The in-page
  // transitions only until first-load-after-restart.bench.ts has its BOUND mode; about 3 min on a 32-core VM, its own
  // part so it never pushes the suite past its cap.
  {
    name: "settled-page",
    file: "settled-page.bench.ts",
    args: ["3", "120"],
    env: { ONLY: "chat_switch,workspace_switch" },
    timeoutMs: 600_000,
    ownPart: true,
  },
  {
    name: "transcript-scroll-frame",
    file: "transcript-scroll-frame.bench.ts",
    args: ["3000", "2"],
    timeoutMs: 240_000,
    builds: ["page:/test/browser/transcript-fling.html"],
  },
  // The RFD 0040 transcript replacement's named fling benchmark. It reports both the current web transcript and
  // a plain-text floor with one schema so a future native arm can join without changing the driver.
  {
    name: "transcript-fling",
    file: "transcript-fling.bench.ts",
    args: [],
    timeoutMs: 900_000,
    ownPart: true,
  },
  // thread-rail-jump takes 24 to 29 s on the perf runner (2026-11-12).
  {
    name: "thread-rail-jump",
    file: "thread-rail-jump.bench.ts",
    args: ["1000", "5"],
    timeoutMs: 90_000,
    builds: ["pane"],
  },
  // ui-stability takes 130 to 134 s on a fast-checks runner (about 225 s on the perf runner) once its Chromium launches.
  { name: "ui-stability", file: "ui-stability.bench.ts", args: ["2"], timeoutMs: 360_000, builds: ["gallery"] },
  // A turn that ends while the reader is scrolled up: CLS, the anchor's drift and rows folded away.
  {
    name: "transcript-turn-end-shift",
    file: "transcript-turn-end-shift.bench.ts",
    args: ["2"],
    timeoutMs: 120_000,
    builds: ["pane"],
  },
  // Recorded and generated acpmux logs played into the pane at top speed: shift on open and while streaming, work per
  // token as rows grow (its slope), long tasks, heap and idle CPU.
  {
    name: "transcript-replay",
    file: "transcript-replay.bench.ts",
    args: ["--turns", "600"],
    // 93 to 99 s on a fast-checks runner (about 165 s on the perf runner, where 150 s timed it out on every tip
    // measurement since 2026-11-12), the same before #40642 and #41096 (94 s at 842118ab39d9).
    timeoutMs: 300_000,
    builds: ["pane"],
  },
  // 50 tool calls landing in a running turn on the wall clock, as an agent sends them: frame gaps, long tasks, a
  // record's arrival to its paint, task ms per call and layout shift.
  {
    name: "tool-call-burst",
    file: "tool-call-burst.bench.ts",
    args: ["--rounds", "3"],
    timeoutMs: 120_000,
    builds: ["pane"],
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
  // A 1,000,000-event chat (CMUX-571, cmux#37713): the pane client's open, one older page and its heap, for long turns
  // and for 4-record turns. perf-cron.py's web-ui-million part runs both (about 2 minutes on a lane VM).
  {
    name: "million-event-chat",
    file: "million-event-chat.bench.ts",
    args: ["1000000", "20"],
    timeoutMs: 300_000,
    ownPart: true,
  },
  {
    name: "million-event-chat-short",
    file: "million-event-chat.bench.ts",
    args: ["1000000", "20"],
    env: { SHAPE: "short" },
    timeoutMs: 300_000,
    ownPart: true,
  },
  // Scrolling up a long chat page by page at 1k, 10k and 100k rows: each older page's ask to its drawn frame (target
  // 50 ms p95), loading and blank frames, the anchor's shift, and the 100k / 1k ratio (target 1.2x). perf-cron.py's
  // web-ui-scroll-up part runs it.
  {
    name: "transcript-scroll-up-scale",
    file: "transcript-scroll-up-scale.bench.ts",
    args: [],
    timeoutMs: 900_000,
    ownPart: true,
  },
  // One orchestrator chat with 16 sub-sessions (8 local worktrees, 8 Cloud) all streaming (RFD 0167 row 12, goal
  // competitive-orchestrator-16): every frame's work at 60 Hz; the p99 is NOW's
  // competitive.orchestrator.p99_frame_ms_16_children. perf-cron.py's web-ui-orchestrator part runs it.
  {
    name: "orchestrator-16",
    file: "orchestrator-16.bench.ts",
    args: ["16", "30"],
    timeoutMs: 300_000,
    ownPart: true,
  },
  // A chat at any length (goal chats-flat-at-any-length): a 100k-row chat opened and grown live, one and 20 at once,
  // against empty chats; renderer idle CPU, streaming CPU and PSS, and their worst ratio. perf-cron.py's web-ui-flat
  // part runs it, under that part's 30-minute run cap.
  {
    name: "chat-100k-flat",
    file: "chat-100k-flat.bench.ts",
    args: ["100000", "20"],
    env: { CASES: "main" },
    // Seven launches, each about a minute of CPU settle and then its windows: still in long_x20 at 1200 s on an
    // 8-vCPU runner (Actions run 45422305557). perf-cron.py's web-ui-flat run cap (2700 s) sits above it.
    timeoutMs: 2_400_000,
    ownPart: true,
  },
  // Ten 100-turn chats in one shared renderer against an empty one (goal memory-per-chat): renderer PSS, MB per chat
  // and chat_pages_memory.n10.ratio_vs_empty. Linux only (/proc). perf-cron.py's web-ui-memory part runs it
  // (`--only chat-pages-memory`).
  {
    name: "chat-pages-memory",
    file: "chat-pages-memory.bench.ts",
    args: ["10", "100"],
    timeoutMs: 300_000,
    ownPart: true,
  },
  // Several heavy coordinators streaming at 10x while readers attach, scroll, find, switch and type (coord-sim's
  // records: cmux-tui/crates/coord-sim, which must be built first; COORD_SIM_BIN names it). Run only by name.
  {
    name: "coord-sim-load",
    file: "coord-sim-load.bench.ts",
    args: ["3", "10", "60", "5000"],
    timeoutMs: 600_000,
    ownPart: true,
  },
  // Its 20 chats grown live to 100k rows each (about 28 minutes on a 4-vCPU runner): perf-cron.py's web-ui-flat-grown
  // part, under that part's 55-minute run cap. Its windows are 5 s (three of each kind, as in the main part) so the
  // repeats fit under that cap.
  {
    name: "chat-100k-flat-grown",
    file: "chat-100k-flat.bench.ts",
    args: ["100000", "20"],
    env: { CASES: "grown-many", IDLE_S: "5", STREAM_S: "5" },
    // Timed out at 1770 s in two perf cron ticks running; perf-cron.py's web-ui-flat-grown run cap (3300 s) sits above.
    timeoutMs: 3_000_000,
    ownPart: true,
  },
  // The sim's stress ladder (goal sim-fidelity-flat-ladder): chats and browser tabs at 1, 10 and 100 in one shared
  // renderer listing 3,000 chats; the cost per added item at 100 over at 10 (sim_ladder.ratio_max). perf-cron.py's
  // web-ui-ladder part runs it, under that part's 30-minute run cap.
  {
    name: "sim-ladder",
    file: "sim-ladder.bench.ts",
    args: ["--sessions", "3000"],
    timeoutMs: 1_700_000,
    ownPart: true,
  },
  // The same sim at a profile of Leo's running NIGHTLY (goal sim-fidelity-flat-ladder): its pages, tabs, listed chats,
  // change rate and load, against its frame p95, keydown, script ms/s and agent renderer RSS; divergence past 1.5x is
  // red. perf-cron.py's web-ui-fidelity part runs it.
  {
    name: "sim-fidelity",
    file: "sim-ladder.bench.ts",
    args: ["--profile", "bench/profiles/leo-nightly.json"],
    timeoutMs: 600_000,
    ownPart: true,
  },
  // Composer typing under load (CMUX-571, Leo 2026-11-16: "but typing under load is not good enough"): 500 keys
  // 20 ms apart in Chromium and WebKit, idle (L0), a focused reply and tool stream (L1), ten other streaming documents
  // (L2) and a focused 100k-row stream (L3); keydown to paint p95/p99 against the report-only 16/33 ms targets
  // (composerTypingRows.ts). perf-cron.py's web-ui-typing part runs it; each load ends by its 120 s safety deadline.
  {
    name: "composer-typing",
    file: "composer-typing.bench.ts",
    args: ["--mode", "L0,L1,L2,L3", "--engines", "chromium,webkit", "--lengths", "60", "--keys", "500", "--gap", "20"],
    timeoutMs: 1_500_000,
    ownPart: true,
  },
  // A fast fling and clicks along the prompt rail in a 1,500-turn paged chat, with 200, 500 and 1,000 listed sessions
  // and a busy daemon (Leo 2026-11-22: "lags on scrolling in general when he's scrolling really fast"). perf-cron.py's
  // web-ui-scroll part runs it (`--only chat-fast-scroll`).
  {
    name: "chat-fast-scroll",
    file: "chat-fast-scroll.bench.ts",
    args: ["--sizes", "200,500,1000", "--turns", "1500", "--seconds", "4", "--clicks", "16"],
    timeoutMs: 900_000,
    ownPart: true,
  },
  // The sidebar chats page flung at 300 and 1,500 px a frame and jumped along its track at 200 to 10,000 Earlier
  // rows, with every row mounted (the app's host today), a same-frame slice host and a one-frame-late one: work per
  // frame and blank frames (the same ask). The web-ui-scroll part runs it too (`--only sidebar-chats-fling`).
  {
    name: "sidebar-chats-fling",
    file: "sidebar-chats-fling.bench.ts",
    args: ["200", "500", "1000", "10000"],
    timeoutMs: 600_000,
    ownPart: true,
  },
  // The power-user input stress harness's long seed (Leo, 2026-11-22: "we need to test like power users more often"):
  // test/power-user-bursts.browser.test.ts with a random seed and 150 waves of overlapping scroll flicks, resizes,
  // pointer sweeps, 15-60 key/s typing, large pastes and chat switches mid-stream, in Chromium and WebKit; its numbers
  // per input class as webui.power_user.* rows and each breach with its replay seed. perf-cron.py's web-ui-power-user
  // part runs it.
  {
    name: "power-user-bursts",
    file: "power-user-bursts.bench.ts",
    args: ["--waves", "150", "--seed", "random", "--engines", "chromium,webkit"],
    timeoutMs: 1_500_000,
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
  // The markdown page at 10 KB to 50 MB, deep nesting, a 5 MB line and a file appended to 50 times: first-screen
  // ms per case, and exits 1 when a case's first screen passes 3x the 10 KB one's. Run with
  // `--only markdown-viewer-stress`.
  {
    name: "markdown-viewer-stress",
    file: "markdown-viewer-stress.bench.ts",
    args: ["2"],
    timeoutMs: 900_000,
    ownPart: true,
  },
  // The same benches on the god session (bench/godFixture.ts: tens of thousands of rows, MB tool outputs, nested
  // subagents, images, months of history). Their rows carry `god` after the prefix (chat_open.god.compact.latest),
  // so each pairs with its ordinary row; perf-cron.py runs them as a part of their own (web-ui-god), beside the
  // ordinary chat-switch and transcript-replay: the five timeouts sum to 1,695 s, under that part's 1,800 s cap.
  // chat-open-god opens the small chat and the god one in the same rounds (PAIRED=1), interleaved with a calibration
  // page (bench/runnerCalibration.ts), so the ordinary chat-open no longer runs in that part: 7 rounds, against the
  // 3 that left chat_open.god.compact.attach_to_latest reading the runner (89 to 174 ms for the same work). 24 s for
  // both chats at 3 rounds on a linux-pool runner (2026-11-19).
  {
    name: "chat-open-god",
    file: "chat-open.bench.ts",
    args: ["7", "300"],
    env: { FIXTURE: "god", PAIRED: "1" },
    timeoutMs: 300_000,
    ownPart: true,
  },
  // A chat's cold open to its composer taking a key, ten rounds (goal startup-every-path; Leo 2026-11-22: "i hope
  // we're still pursuing startup times for the app itself aka percieved time and percieved interactive time"):
  // dom_content_loaded, first_row and composer_interactive with each round's value (COMPOSER=1, chat-open.bench.ts).
  // cmuxterm-hq's synthetic-probes.yml web-startup job runs it (`--only chat-open-startup`) and records the
  // web-chat-open-startup probe's p50 and p95; the perf cron does not.
  {
    name: "chat-open-startup",
    file: "chat-open.bench.ts",
    args: ["10", "300"],
    env: { COMPOSER: "1" },
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

/// What the shared builds of one run may take together, before the first bench. On the small Linux pool runner of
/// perf cron run 45457645242 (2026-11-24) one pane build took 81 s; a 16-core lane VM builds the pane in 12 s, the
/// fling page in 35 s and the gallery in 66 s, so that runner's three are about 13 minutes.
export const SHARED_BUILDS_CAP_MS = 1_200_000;

/// What the benches without `ownPart` and the shared builds may take together: perf-cron.py's 50-minute cap on the
/// web-ui part (LINUX_RUN_SECONDS_BY_PART), less 30 s.
export const SUITE_CAP_MS = 2_970_000;

export type Failure = { bench: string; why: string; tail: string[] };

/// What a failed bench's `tail` carries (pure): its malformed PERF_ROW lines, the last lines of its own output (a bench
/// that says why it failed on stdout, as state-growth's FAIL lines do, would otherwise leave the tail empty) and the
/// last lines of its stderr, each bounded, in that order.
export function failureTail(stdout: string, stderr: string, bad: readonly string[]): string[] {
  const said = stdout.split("\n").filter((line) => line.trim() && !line.startsWith(PERF_ROW_MARK));
  const errors = stderr.split("\n").filter((line) => line.trim());
  return [...bad.slice(-4), ...said.slice(-8), ...errors.slice(-12)];
}

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

async function run(bench: Bench, timeoutMs = bench.timeoutMs, shared: Record<string, string> = {}) {
  return runArgv(["bun", path.join("bench", bench.file), ...bench.args], { ...shared, ...bench.env }, timeoutMs);
}

async function runArgv(argv: string[], env: Record<string, string>, timeoutMs: number) {
  const webviews = path.resolve(import.meta.dir, "..");
  const started = performance.now();
  const proc = Bun.spawn(argv, {
    cwd: webviews,
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill("SIGKILL");
  }, timeoutMs);
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

type SharedBuilds = {
  /// Each build's directory, by SharedBuild, once it finished.
  dirs: Map<SharedBuild, string>;
  /// The pages directory the page builds went to.
  pagesDir?: string;
  /// Each build's exit and seconds, for the report.
  builds: Record<string, { exit: number | null; seconds: number }>;
  release: () => void;
};

/// The builds the selected benches name, each made once (bench/support/prebuild.ts) within SHARED_BUILDS_CAP_MS,
/// so a bench's timeout covers its measuring and not a cold build. Only for a run of two or more benches: a bench run
/// alone (the nightly's `--only NAME --timeout-s N`) builds inside its own timeout as before. A build that fails or
/// runs out of time is left to its benches, which build their own.
async function sharedBuilds(selected: readonly Bench[]): Promise<SharedBuilds> {
  const wanted = selected.length > 1 ? [...new Set(selected.flatMap((bench) => bench.builds ?? []))] : [];
  const made: string[] = [];
  const out: SharedBuilds = {
    dirs: new Map(),
    builds: {},
    release: () => {
      for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
    },
  };
  if (!wanted.length) return out;
  const tmp = process.env.TMPDIR ?? os.tmpdir();
  const deadline = performance.now() + SHARED_BUILDS_CAP_MS;
  for (const build of wanted) {
    const left = Math.round(deadline - performance.now());
    const page = build.startsWith("page:") ? build.slice("page:".length) : undefined;
    let dir: string;
    if (page) {
      if (!out.pagesDir) made.push((out.pagesDir = fs.mkdtempSync(path.join(tmp, "web-ui-suite-pages-"))));
      dir = path.join(out.pagesDir, sharedPageKey("vite.config.ts", page));
    } else {
      made.push((dir = fs.mkdtempSync(path.join(tmp, `web-ui-suite-${build}-`))));
    }
    if (left <= 0) {
      console.log(
        `web-ui-suite: shared ${build} build not made: the ${SHARED_BUILDS_CAP_MS / 1000} s for builds is spent`,
      );
      continue;
    }
    const kind = page ? "page" : build;
    const argv = ["bun", "bench/support/prebuild.ts", kind, page ? out.pagesDir! : dir, ...(page ? [page] : [])];
    const result = await runArgv(argv, {}, left);
    out.builds[build] = { exit: result.exit, seconds: result.seconds };
    const done = page
      ? sharedBuildDir("pages", { [SHARED_BUILD_ENV.pages]: dir })
      : sharedBuildDir(build as "pane" | "gallery", { [SHARED_BUILD_ENV[build as "pane" | "gallery"]]: dir });
    if (result.exit === 0 && done) {
      out.dirs.set(build, dir);
      console.log(`web-ui-suite: shared ${build} build in ${result.seconds} s`);
    } else {
      const why = result.timedOut ? `timed out after ${Math.round(left / 1000)} s` : `exit ${result.exit}`;
      console.log(`web-ui-suite: shared ${build} build failed (${why}); its benches build their own`);
      for (const line of failureTail(result.stdout, result.stderr, [])) console.log(`  prebuild ${build}! ${line}`);
    }
  }
  return out;
}

/// The variables that hand BENCH the shared builds it names (pure).
export function sharedEnv(bench: Bench, shared: Pick<SharedBuilds, "dirs" | "pagesDir">): Record<string, string> {
  const env: Record<string, string> = {};
  for (const build of bench.builds ?? []) {
    if (!shared.dirs.has(build)) continue;
    if (build.startsWith("page:")) env[SHARED_BUILD_ENV.pages] = shared.pagesDir!;
    else env[SHARED_BUILD_ENV[build as "pane" | "gallery"]] = shared.dirs.get(build)!;
  }
  return env;
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
  // `--timeout-s N` replaces the timeout of each bench `--only` names: the nightly interaction-latency job runs one
  // bench at a time on a runner two to three times slower than the perf runner, so it brings its own (TIMEOUT_S in
  // scripts/ci/nightly_interaction_latency.py), and the defaults stay sized to SUITE_CAP_MS for the perf cron.
  const timeoutS = flag("--timeout-s") === undefined ? undefined : Number(flag("--timeout-s"));
  if (timeoutS !== undefined && !(only && Number.isFinite(timeoutS) && timeoutS > 0)) {
    console.error("web-ui-suite: --timeout-s takes a positive number of seconds, with --only");
    process.exit(2);
  }
  const rows: PerfRow[] = [];
  const failed: Failure[] = [];
  const benches: Record<string, { exit: number | null; seconds: number; rows: number; load: number }> = {};
  const selected = BENCHES.filter((each) => (only ? only.includes(each.name) : !each.ownPart));
  const shared = await sharedBuilds(selected);
  for (const bench of selected) {
    console.log(`web-ui-suite: ${bench.name} ${bench.args.join(" ")}`);
    const before = probe();
    const timeoutMs = timeoutS === undefined ? bench.timeoutMs : timeoutS * 1000;
    const result = await run(bench, timeoutMs, sharedEnv(bench, shared));
    const load = contentionFactor([...before, ...probe()]);
    const { rows: measured, bad } = parseRows(result.stdout);
    const got = normalizeRows(measured, load);
    if (load > 1) console.log(`web-ui-suite: ${bench.name} ran on a busy host: its ms rows are divided by ${load}`);
    // The bench's own human output stays readable in the log.
    for (const line of result.stdout.split("\n"))
      if (line && !line.startsWith(PERF_ROW_MARK)) console.log(`  ${bench.name}| ${line}`);
    benches[bench.name] = { exit: result.exit, seconds: result.seconds, rows: got.length, load };
    const why = result.timedOut
      ? `timed out after ${timeoutMs / 1000} s`
      : result.exit !== 0
        ? `exit ${result.exit}`
        : got.length === 0
          ? "printed no PERF_ROW"
          : bad.length
            ? `${bad.length} malformed PERF_ROW line(s)`
            : null;
    if (why) {
      const tail = failureTail(result.stdout, result.stderr, bad);
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
  const report = { rows: sorted, benches, failed, builds: shared.builds };
  shared.release();
  const out = flag("--out");
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 1));
  console.log(JSON.stringify(report));
  process.exit(rows.length ? 0 : 1);
}

if (import.meta.main) await main();
