// l10n-allow-file: benchmark output, not shipped UI.
// The stress ladder of the offline sim: what one more open chat, and one more browser tab, costs at 100 of them
// against at 10. Leo, 2026-11-22: "make sure our offline simulator is properly able to represent my running app and
// also various stress cases, and just... keep it going. the goal is infinity chats, infinity browser tabs, whatever."
// (cmuxterm-hq goals/sim-fidelity-flat-ladder.md.)
//
// The setup is the one cmux#49847's visible-first-load bench found reproduces Leo's NIGHTLY: every agent page in one
// renderer (the app's CEFSwitches.processPerSitePageSchemes; here --process-per-site and each page opened by the
// first), each listing SESSIONS chats, one chat shown and focused. Each axis grows from 1 to the top rung, measured at
// every rung after it settles:
//   chats  one more open chat is one more agent page in the shared renderer, its chat seeded (ROWS rows) and then
//          hidden, as a chat tab not shown is. Awake by default: the app keeps a working hidden chat's page and
//          releases an idle one (HiddenChatPages.swift), so the pages a rung holds are the working ones; --freeze
//          freezes them instead, as browser.freezeHiddenTabs does to a hidden page past 30 s.
//   tabs   one more browser tab is one more page of its own site (tN.test, so its own renderer as the app's tabs
//          have), a stand-in site page (DOM, a timer, an animation, a few MB of heap), hidden the same way.
// At each rung, over WINDOW ms while the focused chat streams nothing and (when the pane has it,
// cmuxAcpmuxDebug.sessionChurn) the list churns at RATE changes per second:
//   cpu_ms_per_s     every renderer's CPU (utime + stime from /proc), ms per second of wall time, the least of the
//                    rung's CPU_WINDOWS windows (other load on a shared runner only adds CPU)
//   cpu_window_ms_per_s  total CPU over total time, so every GC is in it (chats x100 read 1337 ms/s over one window,
//                    ThreadPoolForeg 1137, while the least read flat). Tabs: over CPU_WINDOWS x WINDOW (45 s). Chats:
//                    over whole collection cycles of their shared heap, from the end of one major collection to the end
//                    of the GC_CYCLES-th after it (traced, ladderRatio.ts cycleRate), so no rung holds a collection
//                    more or less by phase; a cycle the cap cuts off counts as open to the run's end (cycleBounds)
//   heap_mb          the renderers' JS heap after a full collection (the chats share one isolate), MB
//   script_ms_per_s  the awake pages' main-thread script time (CDP Performance.getMetrics ScriptDuration), ms per s,
//                    over the same span as cpu_window_ms_per_s
//   pss_mb           every renderer's proportional set size (/proc/PID/smaps_rollup), MB
//   frame_p95_ms     the focused chat's frame intervals (rAF), p95
// The judged number is the marginal ratio: (cost(top) - cost(mid)) / (top - mid) over (cost(mid) - cost(low)) / (mid -
// low), per axis and metric, with a per-item noise floor (FLOOR) under both: flat is 1.0, a per-item cost that grows
// with the count reads above it. Frame p95 is no sum of items, so its ratio is p95(top) / max(p95(mid), 16.7 ms).
// The CPU metrics carry each rung's standard error (whole cycles: their jackknife; else its windows' spread over
// sqrt(n)), and chats script time its cycles' jackknife. Their ratio is the same
// formula; beside it the bench prints FLOOR, each marginal +- 2 standard errors and the interval the ratio lies in
// (ladderRatio.ts ratioInterval), and a row sim_ladder.AXIS.METRIC.ratio_ci (p50 its low end, p95 its high end).
// sim_ladder.ratio_max is the worst; cmuxterm-hq's NOW reads it as benches.rows[key=sim_ladder_marginal_ratio_max].
//   bun bench/sim-ladder.bench.ts [--axes chats,tabs] [--rungs 10,50,100] [--sessions 3000] [--rows 120]
//     [--window 5000] [--settle 20000] [--rate 20] [--gc-cycles 4] [--cycle-cap 170000] [--freeze] [--json out.json]
// Hidden means Chromium's own hidden state (CEF's WasHidden: no frames, no compositor, visibilityState "hidden"), not a
// script override: each added page is a tab, loaded in front and then put behind the focused chat, of a Chrome this bench
// launches and drives through connectOverCDP with noDefaults, because Playwright's own pages get
// Emulation.setFocusEmulationEnabled, which keeps every page visible and drawing (~2 ms/s each). A page that does not
// read hidden fails the run.
// Linux only (it reads /proc); prints SIM-LADDER lines and PERF_ROW lines (sim_ladder.*).
/// <reference types="bun" />
import { sceneTurns } from "./sceneSize";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
import { dlopen, FFIType, ptr } from "bun:ffi";
import {
  cycleBounds,
  cycleRate,
  FLOOR,
  interpolate,
  majorGcEnds,
  marginalRatio,
  type Metric,
  type Sample,
  SIGMAS,
  ratioInterval,
} from "./ladderRatio";
import { perfRow } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const AXES = (flag("--axes") ?? "chats,tabs").split(",") as ("chats" | "tabs")[];
// 10/50/100: both spans (40 then 50 items) are wide enough for a shared runner to resolve a per-item CPU cost; with 1/10/100
// the low span (9 items) read under the noise, the floor became the denominator and a real 0.6 ms/s per tab read 1.2-1.3.
const RUNGS = (flag("--rungs") ?? "10,50,100")
  .split(",")
  .map(Number)
  .sort((a, b) => a - b);
const PROFILE_FILE = flag("--profile");
/// A profile's value by key, wherever its schema nests it (v0 and v1 group keys under pages, sessions, metrics, ...).
type Json = Record<string, unknown>;
const PROFILE: Json | undefined = PROFILE_FILE ? JSON.parse(fs.readFileSync(PROFILE_FILE, "utf8")) : undefined;
function fromProfile(...keys: string[]): number | null {
  const search = (node: unknown, depth: number): number | null => {
    if (!node || typeof node !== "object" || depth > 3) return null;
    for (const key of keys) {
      const value = (node as Json)[key];
      if (typeof value === "number" && Number.isFinite(value)) return value;
    }
    for (const child of Object.values(node as Json)) {
      const found = search(child, depth + 1);
      if (found !== null) return found;
    }
    return null;
  };
  return search(PROFILE, 0);
}
const SESSIONS = Number(flag("--sessions") ?? fromProfile("listed_sessions", "listed") ?? 3000);
const ROWS = Number(flag("--rows") ?? 120);
// The shown chats' log lengths from a profile (perf_sensor.py `transcript_events`); null when it carries none.
const TRANSCRIPT_EVENTS: number[] | null = (() => {
  const list = PROFILE?.transcript_events;
  const events = Array.isArray(list) ? list.filter((n): n is number => typeof n === "number" && n > 0) : [];
  return events.length ? events : null;
})();
// --full-seed: seed chats with the mock's full load turns (tool calls, diffs, long replies) instead of light ones. The
// fidelity mode always does: at the 13:03Z NIGHTLY profile light seeds drew frames at 100 ms p95, full ones at 66.6
// against the app's 66.3.
// --seed-turns-max N: the most turns one seeded chat gets. The mock daemon keeps a chat's whole log inside the page
// (the app's daemon is its own process, and the pane holds only the paged window it attaches), so a profile's full log
// is the sim's cost alone: Leo's 1.64M-event chat (11-26 00:37Z, 251,762 turns) crashed the page while it seeded
// ("evaluate: Target crashed"). The default, 33,334 turns (100k rows), is the largest chat the repo's benches open
// (chat-100k-flat); at the cap the scene read renderer RSS 2028 MB against the app's 1600. A capped seed is reported as
// seed_capped with the turns the profile asked for.
const SEED_TURNS_MAX = Number(flag("--seed-turns-max") ?? 33_334);
const FULL_SEED = argv.includes("--full-seed") || PROFILE !== undefined;
const WINDOW_MS = Number(flag("--window") ?? 5000);
// The ladder reads CPU over 9 windows of 5 s per rung, 45 s. A hidden item costs well under 1 ms/s, so a rung's reading
// must resolve a few ms/s over 40-50 items, and three 5 s windows could not: the chats share one V8 heap, a major
// collection of it costs CPU in step with the heap (x10 at 190 MB 0.8-1.6 s, x50 at 830 MB about 4 s) and V8 spaces
// them by a limit that grows with the heap (x10 about every 25 s, x100 none in 45 s), so whether a window held one was
// phase. Three runs at one head on 32 cores read ratio_max 1.44, 1.01 and 1.00, CI 4.0, and chats CPU ratios of 0.2,
// 0.11 and -0.31: two noises divided. Forcing a collection before each window to fix the phase read worse (1.96: the
// forced one sets off a natural one 7-8 s later, inside x10's window and past x50's). So every collection that lands
// in 45 s counts, at the rung's own rate, and the spread of the 9 windows says how far the reading can be trusted.
// The fidelity mode keeps its 3 (its streams last the settle and three windows).
const CPU_WINDOWS = Number(flag("--cpu-windows") ?? (PROFILE ? 3 : 9));
// The chats axis reads CPU and script time over whole collection cycles of the shared heap instead (ladderRatio.ts
// cycleRate): nine 5 s windows still read chats CPU to +- 13 ms/s, as whether the 45 s held a 1.3 s (x10) or 5.9 s
// (x50) collection was phase. Each chats rung runs until GC_CYCLES major collections after its first have ended, at
// most CYCLE_CAP_MS (x10 cycles every 8 s, x50 and x100 every 15-20 s), and its rates are over exactly those cycles.
// The bound: three chats rungs at most 3 x (CYCLE_CAP_MS + SETTLE_MS) of measuring, 9.5 min at the defaults.
const GC_CYCLES = Number(flag("--gc-cycles") ?? 4);
const CYCLE_CAP_MS = Number(flag("--cycle-cap") ?? 170_000);
// The awake pages' ScriptDuration is read every 10 s: each reading is a CDP call per page (100 at x100) and costs the
// renderer time of its own, in step with the pages.
const SCRIPT_SAMPLE_MS = 10_000;
const changesPerMin = fromProfile("sessions_changed_per_min");
const RATE = Number(flag("--rate") ?? (changesPerMin !== null ? changesPerMin / 60 : 20));
const FREEZE = argv.includes("--freeze");
const SETTLE_MS = Number(flag("--settle") ?? 20_000);
// Extra Chrome switches, comma-separated (e.g. --disable-features=IntensiveWakeUpThrottling), for experiments.
const CHROME_ARGS = (flag("--chrome-args") ?? "").split(",").filter(Boolean);
// --timer-census: count every timer callback a page runs, by the frame that scheduled it, and print the hidden pages'
// top sources after the last rung (what a hidden chat wakes for).
const TIMER_CENSUS = argv.includes("--timer-census");
// --churn-hidden: churn every chat page's list, not only the focused one's. In the app every agent page holds its own
// daemon connection and hears every listed chat's change; here each page's mock is its own daemon, so without this flag
// the hidden chats hear no change at all. Off by default, so the ladder's numbers stay comparable across runs.
const CHURN_HIDDEN = argv.includes("--churn-hidden");
// --alloc-profile: over each rung's first window, a sampled allocation profile of the chats' shared isolate
// (HeapProfiler.startSampling on the focused chat, which samples every page of its renderer): bytes allocated per
// second and the top allocation sites by self size, as SIM-LADDER   alloc lines.
const ALLOC_PROFILE = argv.includes("--alloc-profile");
const JSON_OUT = flag("--json");
// --profile FILE (read above): the fidelity mode. Instead of the ladder, build one scene from a profile of a running app
// (cmux-app-profile, from leo-workspace tools/perf_sensor.py): its agent pages, browser tabs, listed sessions, change
// rate and load, then compare the sim's frame p95, keydown, script ms/s and agent renderer RSS with the app's.
// --hogs N: CPU-bound processes beside the scene while it is measured (the app's machine load). Default: the
// profile's load per core over this machine's cores, at most one per core.
const HOGS = flag("--hogs");
const DIR = flag("--dir") ?? path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const VERSION = 6;
if (RUNGS.length !== 3 || RUNGS.some((n) => !Number.isInteger(n) || n < 1) || RUNGS[0] === RUNGS[1]) {
  console.error("usage: --rungs LOW,MID,TOP (three distinct counts, e.g. 1,10,100)");
  process.exit(2);
}
if (process.platform !== "linux") {
  console.error("sim-ladder: Linux only (renderer CPU and memory from /proc)");
  process.exit(2);
}

const ticksPerSecond = 100; // USER_HZ on every Linux the runners have.
function childrenOf(): Map<number, number[]> {
  const children = new Map<number, number[]>();
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, "utf8");
      const parent = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      children.set(parent, [...(children.get(parent) ?? []), Number(entry)]);
    } catch {
      // Gone between the listing and the read.
    }
  }
  return children;
}
function renderers(root: number): number[] {
  const children = childrenOf();
  const out: number[] = [];
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      try {
        if (fs.readFileSync(`/proc/${child}/cmdline`, "utf8").includes("--type=renderer")) out.push(child);
      } catch {
        // Gone.
      }
      walk(child);
    }
  };
  walk(root);
  return out;
}
function cpuTicks(pid: number, file = `/proc/${pid}/stat`): number {
  try {
    const stat = fs.readFileSync(file, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return Number(fields[11]) + Number(fields[12]);
  } catch {
    return 0;
  }
}
/// CPU ticks per thread name (/proc/PID/task/TID/comm) over the renderers: where a rung's CPU goes.
function threadTicks(pids: number[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const pid of pids) {
    let tids: string[] = [];
    try {
      tids = fs.readdirSync(`/proc/${pid}/task`);
    } catch {
      continue;
    }
    for (const tid of tids) {
      try {
        const name = fs.readFileSync(`/proc/${pid}/task/${tid}/comm`, "utf8").trim().replace(/\d+$/, "N");
        const ticks = cpuTicks(Number(tid), `/proc/${pid}/task/${tid}/stat`);
        out.set(name, (out.get(name) ?? 0) + ticks);
      } catch {
        // Gone.
      }
    }
  }
  return out;
}
function pssMB(pid: number): number {
  try {
    const rollup = fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8");
    return Number(/^Pss:\s+(\d+) kB/m.exec(rollup)?.[1] ?? 0) / 1024;
  } catch {
    return 0;
  }
}
/// The renderers' PSS split by kind (smaps_rollup), MB, with the median renderer's: what a rung's PSS is made of.
function pssSplit(pids: number[]): string {
  const sum: Record<string, number> = {};
  const each: number[] = [];
  for (const pid of [...pids].sort((a, b) => a - b)) {
    try {
      const rollup = fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8");
      for (const key of ["Pss", "Pss_Anon", "Pss_File", "Pss_Shmem", "Private_Dirty", "Swap"]) {
        const kb = Number(new RegExp(`^${key}:\\s+(\\d+) kB`, "m").exec(rollup)?.[1] ?? 0);
        sum[key] = (sum[key] ?? 0) + kb / 1024;
        if (key === "Pss") each.push(kb / 1024);
      }
    } catch {
      // Gone.
    }
  }
  console.log(`SIM-LADDER   pss by renderer in pid order ${each.map((v) => Math.round(v)).join(" ")}`);
  each.sort((a, b) => a - b);
  const fmt = Object.entries(sum).map(([k, v]) => `${k} ${Math.round(v)}`);
  return `${fmt.join(", ")} | renderer pss min/median/max ${each
    .map((v) => Math.round(v * 10) / 10)
    .filter((_, i) => i === 0 || i === Math.floor(each.length / 2) || i === each.length - 1)
    .join("/")}`;
}
const p95 = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.min(s.length - 1, Math.floor((s.length - 1) * 0.95))]! : 0;
};

/// A browser tab's stand-in site: a few thousand nodes, a ticking clock, an animation and a few MB of heap.
const SITE_HTML = `<!doctype html><meta charset=utf-8><title>site</title>
<style>.spin{width:40px;height:40px;background:#48f;animation:s 1s linear infinite}@keyframes s{to{transform:rotate(1turn)}}</style>
<div class=spin></div><div id=clock></div><div id=feed></div>
<script>
const feed = document.getElementById("feed");
for (let i = 0; i < 1500; i += 1) { const p = document.createElement("p"); p.textContent = "Item " + i + " lorem ipsum dolor"; feed.append(p); }
window.__keep = Array.from({ length: 40000 }, (_, i) => ({ i, s: "row " + i }));
setInterval(() => { document.getElementById("clock").textContent = new Date().toISOString(); }, 250);
</script>`;

/// A Chrome of this bench's own (so a descendant of this process, its renderers ours to read), its DevTools endpoint
/// from stderr: the installed Chrome in its new headless mode, the headless shell only where no Chrome is installed.
/// The shell (CMUX_CHROME_HEADLESS_SHELL, which ensure-system-chrome.sh exports to the job) has no window to put a tab
/// behind, so every page reads "visible" and keeps drawing: on chrome-headless-shell 157.0.8103.78 a tab behind the
/// focused chat read visible at 19 frames in 300 ms, where Chrome 157 --headless=new read hidden at 0. With the shell
/// first, every perf cron run since 2026-11-25 08:54Z ended "sim-ladder: chats #N reads visible ..., not hidden" (exit
/// 1; run 45643103662 job 139309163781) and NOW's sim_ladder/sim_fidelity rows stopped at 02:20Z.
async function launchChrome(): Promise<{
  browser: Browser;
  close: () => Promise<void>;
}> {
  const chrome = Bun.which("google-chrome") || Bun.which("google-chrome-stable");
  const shell = chrome ? undefined : process.env.CMUX_CHROME_HEADLESS_SHELL;
  const exe = chrome || shell;
  if (!exe) throw new Error("sim-ladder: no Chrome (set CMUX_CHROME_HEADLESS_SHELL or install google-chrome)");
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "sim-ladder-"));
  const proc = Bun.spawn(
    [
      exe,
      ...(shell ? [] : ["--headless=new"]),
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1100,820",
      "--process-per-site",
      "--host-resolver-rules=MAP *.test 127.0.0.1",
      // A page hidden past 5 min has its timers cut to one wake-up a minute. Rungs load over minutes, so with it on,
      // x100's early chats were throttled and x10's were not, and the ratio read the pages' age. Off, every rung
      // measures freshly hidden pages: the worst case, as a chat Leo just switched away from.
      // SpareRendererForSitePerProcess: Chrome keeps one warm renderer ready, which a new tab takes, so a rung's first
      // tabs add no renderer of their own (x1 to x10 added 9 tabs and 7 renderers, x10 to x100 90 and 90) and the low
      // PSS slope read 13.9 MB a tab against 16.4 at the top. Off, each tab's renderer starts with its tab.
      "--disable-features=IntensiveWakeUpThrottling,SpareRendererForSitePerProcess",
      // Ubuntu 24.04 runners restrict unprivileged user namespaces with AppArmor, so Chrome's sandbox cannot start and
      // Chrome exits before it prints a DevTools endpoint (web-ui-ladder and web-ui-fidelity's `exit 1` on the perf
      // cron, run 45408142192). The bench loads only its own local pages; every Playwright launch the other benches
      // use passes the same flag. (#54319 added it; a conflict resolution in #52348/#54537 dropped it.)
      "--no-sandbox",
      ...CHROME_ARGS,
      "about:blank",
    ],
    { stdout: "ignore", stderr: "pipe" },
  );
  const reader = proc.stderr.getReader();
  let text = "";
  const deadline = Date.now() + 30_000;
  let ws: string | undefined;
  while (!ws && Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    text += new TextDecoder().decode(value);
    ws = /DevTools listening on (ws:\/\/\S+)/.exec(text)?.[1];
  }
  if (!ws) {
    proc.kill();
    throw new Error(`sim-ladder: Chrome printed no DevTools endpoint: ${text.slice(-400)}`);
  }
  // Keep draining stderr so Chrome never blocks on a full pipe.
  void (async () => {
    while (!(await reader.read()).done);
  })().catch(() => undefined);
  const browser = await chromium.connectOverCDP(ws, { noDefaults: true });
  return {
    browser,
    close: async () => {
      await browser.close().catch(() => undefined);
      proc.kill();
      await proc.exited;
      fs.rmSync(profile, { recursive: true, force: true });
    },
  };
}

/// Chromium's own visibility and frame rate of a page: a hidden page reads "hidden" and draws no frame.
const visibility = (page: Page) =>
  page.evaluate(
    () =>
      new Promise<[string, number]>((resolve) => {
        let frames = 0;
        requestAnimationFrame(() => (frames += 1));
        setTimeout(() => resolve([document.visibilityState, frames]), 300);
      }),
  );

type Item = { page: Page; cdp: CDPSession; awake: boolean };

/// Waits for the renderers to settle after a rung's pages load (compile, GC and decode bursts run for seconds after a
/// load; chats x10 read 208 ms/s mid-burst against 86 at x100): until two 1 s readings agree within 25% (or 5 ms/s),
/// at most SETTLE_MS. Returns whether they did.
async function settle(rootPid: number, focused: Page): Promise<boolean> {
  const deadline = Date.now() + SETTLE_MS;
  let last = -1;
  while (Date.now() < deadline) {
    const pids = renderers(rootPid);
    const t0 = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
    await focused.waitForTimeout(1000);
    const now = ((pids.reduce((sum, pid) => sum + cpuTicks(pid), 0) - t0) / ticksPerSecond) * 1000;
    if (last >= 0 && Math.abs(now - last) <= Math.max(5, 0.25 * Math.max(now, last))) return true;
    last = now;
  }
  return false;
}

type AllocNode = {
  callFrame: { functionName: string; url: string; lineNumber: number };
  selfSize: number;
  children: AllocNode[];
};
/// A sampled allocation profile as bytes per second and its top sites: each by its own frame and the two frames above
/// it, so a site reached from many callers (JSON.parse) is told apart by who called it.
function printAllocations(profile: { head: AllocNode }, secs: number): void {
  const sites = new Map<string, number>();
  let total = 0;
  const name = (node: AllocNode) =>
    `${node.callFrame.functionName || "(anon)"}@${node.callFrame.url.split("/").pop()?.split("?")[0] ?? ""}:${node.callFrame.lineNumber + 1}`;
  const walk = (node: AllocNode, stack: string[]) => {
    const here = [...stack, name(node)];
    if (node.selfSize > 0) {
      total += node.selfSize;
      const key = here.slice(-3).reverse().join(" < ");
      sites.set(key, (sites.get(key) ?? 0) + node.selfSize);
    }
    for (const child of node.children) walk(child, here);
  };
  walk(profile.head, []);
  console.log(`SIM-LADDER   alloc ${Math.round(total / 1024 / secs)} KB/s sampled over ${secs.toFixed(1)} s`);
  for (const [key, bytes] of [...sites].sort((a, b) => b[1] - a[1]).slice(0, 25))
    console.log(`SIM-LADDER   alloc ${Math.round(bytes / 1024 / secs)} KB/s ${key}`);
}

/// The last rung's load collection (renderer CPU ms), kept for the summary printed at the end.
let lastLoadMs = 0;
/// The last measure()'s standard errors, ms/s, by metric: whole cycles' jackknife, or fixed windows' spread over sqrt(n).
let lastSe: Partial<Record<Metric, number>> = {};
/// The last measure()'s whole collection cycles (null: a fixed-window rung).
let lastCycles: number | null = null;

const libc = dlopen("libc.so.6", {
  clock_gettime: { args: [FFIType.i32, FFIType.ptr], returns: FFIType.i32 },
});
const clockBuf = new BigInt64Array(2);
/// CLOCK_MONOTONIC in microseconds: the clock of Chrome's trace timestamps on Linux.
function monoUs(): number {
  libc.symbols.clock_gettime(1, ptr(clockBuf));
  return Number(clockBuf[0]) * 1e6 + Number(clockBuf[1]) / 1e3;
}

/// Traces V8 (category "v8": MajorGC carries the pause's start, length and heap) in 15 s segments until the largest
/// heap's renderer has ended GC_CYCLES + 1 major collections, or until the deadline (performance.now()). Chrome hands a
/// trace's events over only when it ends, hence the segments; a collection that falls in the few ms between two is
/// missed, which moves no rate (the rate is over whatever whole cycles lie between the first and last end seen).
async function traceMajorGcs(browserCdp: CDPSession, deadline: number) {
  const events: { pid: number; ts: number; dur: number; heapBefore: number }[] = [];
  const onData = (e: { value: Record<string, any>[] }) => {
    for (const ev of e.value)
      if (ev.name === "MajorGC" && ev.ph === "X")
        events.push({ pid: ev.pid, ts: ev.ts, dur: ev.dur ?? 0, heapBefore: ev.args?.usedHeapSizeBefore ?? 0 });
  };
  browserCdp.on("Tracing.dataCollected", onData as any);
  try {
    for (;;) {
      await browserCdp.send("Tracing.start", {
        traceConfig: { includedCategories: ["v8"], recordMode: "recordAsMuchAsPossible" },
        transferMode: "ReportEvents",
      });
      await new Promise((resolve) => setTimeout(resolve, Math.max(0, Math.min(15_000, deadline - performance.now()))));
      const complete = new Promise((resolve) => browserCdp.once("Tracing.tracingComplete", resolve));
      await browserCdp.send("Tracing.end");
      await complete;
      const found = majorGcEnds(events);
      if (found.ends.length >= GC_CYCLES + 1 || performance.now() >= deadline) return found;
    }
  } finally {
    browserCdp.off("Tracing.dataCollected", onData as any);
  }
}
const loadMs: Record<string, number> = {};

async function measure(
  rootPid: number,
  items: Item[],
  focused: Page,
  browserCdp: CDPSession,
  cycles = false,
): Promise<Sample> {
  // Loading a rung leaves garbage (the seeded chats' parse and render temporaries: x50 held 1.8-2.2 GB live against 855 MB
  // after a collection) that V8 collects at a moment of its own: one major collection of 4-6 s of ThreadPoolForeground CPU
  // landed inside the window of x50 in every run (610, 658, 326, 794 ms/s), a load cost read as the rung's steady state.
  // Collect it first, once per isolate as the heap reading below does, and log what that took: the load's cost stays visible.
  const gcPids = renderers(rootPid);
  const gcTicks0 = gcPids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
  await Promise.all(
    items
      .filter((item, index) => index === 0 || item.page.url() !== items[0]!.page.url())
      .map((item) =>
        Promise.race([
          item.cdp.send("HeapProfiler.collectGarbage").catch(() => undefined),
          new Promise((resolve) => setTimeout(resolve, 20_000)),
        ]),
      ),
  );
  lastLoadMs = Math.round(((gcPids.reduce((sum, pid) => sum + cpuTicks(pid), 0) - gcTicks0) / ticksPerSecond) * 1000);
  console.log(`SIM-LADDER   load collection ${lastLoadMs} ms of renderer CPU`);
  const settled = await settle(rootPid, focused);
  if (!settled) console.log(`SIM-LADDER   not settled in ${SETTLE_MS} ms`);
  const pids = renderers(rootPid);
  // No renderer found is a broken walk (a Chrome not ours, a /proc we cannot read), never a free rung.
  if (pids.length < 1) throw new Error("sim-ladder: the renderer walk found no renderer under this process");
  const awake = items.filter((item) => item.awake);
  const script = async () => {
    const all = await Promise.all(
      awake.map((item) =>
        Promise.race([
          item.cdp.send("Performance.getMetrics"),
          new Promise<null>((resolve) => setTimeout(() => resolve(null), 3000)),
        ]),
      ),
    );
    return all.reduce((sum, m) => sum + (m?.metrics.find((x) => x.name === "ScriptDuration")?.value ?? 0), 0);
  };
  const cpuNow = () => (pids.reduce((sum, pid) => sum + cpuTicks(pid), 0) / ticksPerSecond) * 1000;
  // Cumulative readings on CLOCK_MONOTONIC (us), the clock of Chrome's trace timestamps: renderer CPU ms every 100 ms,
  // the awake pages' ScriptDuration (ms) every SCRIPT_SAMPLE_MS. A rung's rates are read off them between any two
  // moments: its fixed windows, or the ends of whole collection cycles.
  const cpuT: number[] = [];
  const cpuV: number[] = [];
  const scriptT: number[] = [];
  const scriptV: number[] = [];
  const sampleCpu = () => {
    cpuT.push(monoUs());
    cpuV.push(cpuNow());
  };
  const sampleScript = async () => {
    const from = monoUs();
    const value = await script();
    scriptT.push((from + monoUs()) / 2);
    scriptV.push(value * 1000);
  };
  const threads0 = threadTicks(pids);
  await sampleScript();
  sampleCpu();
  const t0 = performance.now();
  const start = cpuT[0]!;
  const cpuTimer = setInterval(sampleCpu, 100);
  let scriptOn = true;
  const scriptLoop = (async () => {
    while (scriptOn) {
      await new Promise((resolve) => setTimeout(resolve, SCRIPT_SAMPLE_MS));
      if (scriptOn) await sampleScript();
    }
  })();
  await focused.evaluate(() => {
    const w = window as any;
    w.__slFrames = [];
    w.__slOn = true;
    let last = performance.now();
    const tick = (now: number) => {
      if (!w.__slOn) return;
      w.__slFrames.push(now - last);
      last = now;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame((now) => {
      last = now;
      requestAnimationFrame(tick);
    });
  });
  // A once-a-second trace over the run: renderer CPU ms in the second, its ThreadPoolForeground share (V8's parallel GC
  // workers), and the focused isolate's JS heap in MB. A burst that lands with a heap drop is a major collection.
  const trace: string[] = [];
  let tracing = true;
  const sampler = (async () => {
    let lastTicks = cpuNow();
    let lastPool = threadTicks(pids).get("ThreadPoolForeg") ?? 0;
    while (tracing) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const nowMs = cpuNow();
      const pool = threadTicks(pids).get("ThreadPoolForeg") ?? 0;
      const heapNow = await Promise.race([
        items[0]!.cdp
          .send("Performance.getMetrics")
          .then((m) => Math.round((m.metrics.find((x) => x.name === "JSHeapUsedSize")?.value ?? 0) / 1048576))
          .catch(() => -1),
        new Promise<number>((resolve) => setTimeout(() => resolve(-1), 500)),
      ]);
      trace.push(
        `${Math.round(nowMs - lastTicks)}/${Math.round(((pool - lastPool) / ticksPerSecond) * 1000)}/${heapNow}`,
      );
      lastTicks = nowMs;
      lastPool = pool;
    }
  })();
  if (ALLOC_PROFILE) await items[0]!.cdp.send("HeapProfiler.enable");
  if (ALLOC_PROFILE) await items[0]!.cdp.send("HeapProfiler.startSampling", { samplingInterval: 16384 });
  // The focused chat's frames over the first window.
  await focused.waitForTimeout(WINDOW_MS);
  const frames = (await focused.evaluate(() => {
    const w = window as any;
    w.__slOn = false;
    return w.__slFrames as number[];
  })) as number[];
  if (ALLOC_PROFILE)
    printAllocations((await items[0]!.cdp.send("HeapProfiler.stopSampling")).profile, (performance.now() - t0) / 1000);
  // The chats axis runs until GC_CYCLES whole cycles of the shared heap have ended (at most CYCLE_CAP_MS); the rest
  // run CPU_WINDOWS windows.
  let gc: { pid: number | null; ends: number[] } = { pid: null, ends: [] };
  if (cycles) gc = await traceMajorGcs(browserCdp, t0 + CYCLE_CAP_MS);
  else await focused.waitForTimeout(Math.max(0, CPU_WINDOWS * WINDOW_MS - (performance.now() - t0)));
  scriptOn = false;
  clearInterval(cpuTimer);
  await scriptLoop;
  sampleCpu();
  await sampleScript();
  tracing = false;
  await sampler;
  const end = cpuT[cpuT.length - 1]!;
  const secs = (end - start) / 1e6;
  console.log(`SIM-LADDER   per-second cpu ms / pool ms / js heap MB: ${trace.join(" ")}`);
  const threads = [...threadTicks(pids)]
    .map(([name, t]) => [name, Math.round((((t - (threads0.get(name) ?? 0)) / ticksPerSecond) * 1000) / secs)] as const)
    .filter(([, ms]) => ms > 0)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 6);
  // One renderer's pages share one V8 isolate, so the focused page's heap numbers are the shared heap's.
  const heap = (await items[0]!.cdp.send("Performance.getMetrics")).metrics;
  const heapMB = (name: string) => Math.round((heap.find((m) => m.name === name)?.value ?? 0) / 1048576);
  console.log(
    `SIM-LADDER   threads ms/s ${threads.map(([n, ms]) => `${n} ${ms}`).join(", ")} | js heap ${heapMB("JSHeapUsedSize")}/${heapMB("JSHeapTotalSize")} MB`,
  );
  // Fixed windows off the CPU timeline: the run cut into WINDOW_MS windows (the profile mode: its first window in
  // thirds). Their least is cpu_ms_per_s (other load on a shared runner only adds CPU); their spread over sqrt(n) is the
  // standard error of a fixed-window mean.
  const windowsOf = (from: number, to: number, lengthUs: number) => {
    const out: number[] = [];
    for (let a = from; a + lengthUs <= to + 1; a += lengthUs)
      out.push(((interpolate(cpuT, cpuV, a + lengthUs) - interpolate(cpuT, cpuV, a)) * 1e6) / lengthUs);
    return out;
  };
  const windows = windowsOf(start, end, WINDOW_MS * 1000);
  const thirds = windowsOf(start, start + WINDOW_MS * 1000, (WINDOW_MS * 1000) / 3);
  const avg = windows.reduce((sum, w) => sum + w, 0) / Math.max(1, windows.length);
  const sd = Math.sqrt(windows.reduce((sum, w) => sum + (w - avg) ** 2, 0) / Math.max(1, windows.length - 1));
  const windowSe = sd / Math.sqrt(Math.max(1, windows.length));
  const meanAll = ((cpuV[cpuV.length - 1]! - cpuV[0]!) * 1e6) / (end - start);
  const scriptAll = ((scriptV[scriptV.length - 1]! - scriptV[0]!) * 1e6) / (scriptT[scriptT.length - 1]! - scriptT[0]!);
  console.log(
    `SIM-LADDER   cpu windows ms/s ${windows.map(Math.round).join(", ")} | mean ${Math.round(meanAll)} +- ${windowSe.toFixed(1)} (se) over ${secs.toFixed(0)} s`,
  );
  let cpuRate =
    CPU_WINDOWS > 3 || cycles ? meanAll : [...windows].sort((a, b) => a - b)[Math.floor(windows.length / 2)]!;
  let scriptRate = scriptAll;
  lastSe = { cpu_window_ms_per_s: windowSe, cpu_ms_per_s: windowSe };
  lastCycles = null;
  if (cycles) {
    // Whole cycles: from the end of the first major collection seen to the end of the last, every collection between
    // counted once. Under one whole cycle in the cap, the whole run's mean stands, with its windows' error.
    // When the cap ends the trace before GC_CYCLES cycles close, the cycles that did close are the short ones (x100's
    // collections came 35 s apart, then none in the next 112 s: closed cycles alone read 353 ms/s against 143 at x10),
    // so the open tail from the last collection to the run's end counts as one more cycle whose collection has not come
    // yet. Both rates print: closed cycles only (short-biased, high) and with the open tail (one collection short, low).
    const { bounds, capped } = cycleBounds(gc.ends, end, GC_CYCLES);
    const closed = capped ? cycleRate(gc.ends, cpuT, cpuV) : null;
    const cpu = cycleRate(bounds, cpuT, cpuV);
    const scr = cycleRate(bounds, scriptT, scriptV);
    lastCycles = cpu?.cycles ?? 0;
    if (cpu && scr) {
      cpuRate = cpu.rate * 1e6;
      scriptRate = scr.rate * 1e6;
      lastSe = {
        ...lastSe,
        cpu_window_ms_per_s: cpu.se === null ? windowSe : cpu.se * 1e6,
        ...(scr.se === null ? {} : { script_ms_per_s: scr.se * 1e6 }),
      };
      console.log(
        `SIM-LADDER   whole gc cycles ${cpu.cycles} over ${(cpu.span / 1e6).toFixed(1)} s (renderer ${gc.pid}, major gc ends at ${gc.ends.map((t) => ((t - start) / 1e6).toFixed(1)).join(", ")} s${capped ? `, the last ${((end - gc.ends[gc.ends.length - 1]!) / 1e6).toFixed(1)} s open at the cap` : ""}): cpu ${cpuRate.toFixed(1)} +- ${(cpu.se === null ? windowSe : cpu.se * 1e6).toFixed(1)} ms/s (per cycle ${cpu.perCycle.map((r) => Math.round(r * 1e6)).join(", ")}${closed ? `; closed cycles only ${(closed.rate * 1e6).toFixed(1)}` : ""}), script ${scriptRate.toFixed(1)} +- ${scr.se === null ? "?" : (scr.se * 1e6).toFixed(1)} ms/s`,
      );
    } else
      console.log(
        `SIM-LADDER   whole gc cycles 0: ${gc.ends.length} major gc end(s) in ${secs.toFixed(0)} s (cap ${CYCLE_CAP_MS / 1000} s); the run's mean stands`,
      );
  }
  // Memory after a full collection: what the pages keep, not how far each heap has grown since its last GC (chats x100
  // read 4583 MB in one run and 5331 in the next, at the same pages).
  await Promise.all(
    // One collection per renderer: the chats share one isolate (the focused chat's), each tab has its own.
    items
      .filter((item, index) => index === 0 || item.page.url() !== items[0]!.page.url())
      .map((item) =>
        Promise.race([
          item.cdp.send("HeapProfiler.collectGarbage").catch(() => undefined),
          new Promise((resolve) => setTimeout(resolve, 10_000)),
        ]),
      ),
  );
  // The heap after the collection, one reading per renderer (its isolate), summed.
  const heaps = await Promise.all(
    items
      .filter((item, index) => index === 0 || item.page.url() !== items[0]!.page.url())
      .map((item) =>
        Promise.race([
          item.cdp
            .send("Performance.getMetrics")
            .then((m) => m.metrics.find((x) => x.name === "JSHeapUsedSize")?.value ?? 0)
            .catch(() => 0),
          new Promise<number>((resolve) => setTimeout(() => resolve(0), 3000)),
        ]),
      ),
  );
  console.log(`SIM-LADDER   pss split MB ${pssSplit(pids)}`);
  return {
    cpu_ms_per_s: Math.round(CPU_WINDOWS > 3 || cycles ? Math.min(...windows) : Math.min(...thirds)),
    cpu_window_ms_per_s: Math.round(cpuRate),
    heap_mb: Math.round(heaps.reduce((sum, bytes) => sum + bytes, 0) / 1048576),
    script_ms_per_s: Math.round(scriptRate),
    pss_mb: Math.round(pids.reduce((sum, pid) => sum + pssMB(pid), 0)),
    frame_p95_ms: Math.round(p95(frames) * 10) / 10,
  };
}

const releases: (() => unknown)[] = [];
const port = await servePane(DIR, { unminified: argv.includes("--unminified") }, releases);
const site = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch: () => new Response(SITE_HTML, { headers: { "content-type": "text/html" } }),
});
releases.push(() => site.stop(true));
const report: Record<string, unknown> = {
  version: VERSION,
  rungs: RUNGS,
  sessions: SESSIONS,
  rows: ROWS,
  window_ms: WINDOW_MS,
  cpu_windows: CPU_WINDOWS,
  rate: RATE,
  freeze: FREEZE,
  cores: os.cpus().length,
  load1: os.loadavg()[0],
};
const ratios: Record<string, number> = {};

/// The resident set of one process, MB.
function rssMB(pid: number): number {
  try {
    return Number(/^VmRSS:\s+(\d+) kB/m.exec(fs.readFileSync(`/proc/${pid}/status`, "utf8"))?.[1] ?? 0) / 1024;
  } catch {
    return 0;
  }
}

/// A profile's scene: its pages, sessions and load. `mix` set, runAxis builds this one scene and measures it once.
/// `visible` of the chats are shown (each in a window of its own) and stream a reply a delta every `streamMs`.
type Mix = { chats: number; visible: number; tabs: number; hogs: number; streamMs: number | null };
type Scene = { sample: Sample; agentRssMB: number; churn: boolean };

async function runAxis(axis: "chats" | "tabs", mix?: Mix): Promise<Scene | undefined> {
  const chrome = await launchChrome();
  const browser = chrome.browser;
  // The launched Chrome is this process's descendant, and one axis runs at a time: its renderers are ours.
  const rootPid = process.pid;
  const samples: Record<number, Sample> = {};
  const ses: Record<number, Partial<Record<Metric, number>>> = {};
  const cycleCounts: Record<number, number | null> = {};
  let churn: Promise<unknown> | null = null;
  try {
    const browserCdp = await browser.newBrowserCDPSession();
    // The default context: with noDefaults it is the one Playwright adds no focus emulation to.
    const context = browser.contexts()[0]!;
    // The fidelity mode lists the sessions as a fleet Mac's rows (long titles, previews, peers, PRs; mockFixture.ts
    // `fleetListedSession`), as the profiled app's 3,761-row list is; the ladder keeps its light rows.
    await context.addInitScript(
      ([size, shape]) => {
        (globalThis as any).cmuxAcpmuxMockListSize = size;
        if (shape) (globalThis as any).cmuxAcpmuxMockListShape = shape;
      },
      [SESSIONS, PROFILE !== undefined ? "fleet" : null] as const,
    );
    if (TIMER_CENSUS)
      await context.addInitScript(() => {
        const counts: Record<string, number> = ((globalThis as any).__slTimers = {});
        const site = () => {
          const lines = (new Error().stack ?? "").split("\n").slice(3, 6);
          return lines
            .map((l) =>
              l
                .trim()
                .replace(/^at /, "")
                .replace(/\?[^:)]*/, ""),
            )
            .join(" < ");
        };
        const wrap = (name: "setTimeout" | "setInterval") => {
          const original = (globalThis as any)[name].bind(globalThis);
          (globalThis as any)[name] = (fn: unknown, ...rest: unknown[]) => {
            if (typeof fn !== "function") return original(fn, ...rest);
            const key = `${name} ${String(rest[0] ?? 0)}ms ${site()}`;
            return original(
              (...args: unknown[]) => {
                counts[key] = (counts[key] ?? 0) + 1;
                return (fn as (...a: unknown[]) => unknown)(...args);
              },
              ...rest,
            );
          };
        };
        wrap("setTimeout");
        wrap("setInterval");
      });
    const url = `http://127.0.0.1:${port}/?mock`;
    const focused = context.pages()[0] ?? (await context.newPage());
    await focused.goto(url);
    await focused.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, {
      timeout: 60_000,
    });
    // `slot`: the chat's place among the shown chats (0 the focused one), whose log lengths a profile lists as
    // transcript_events; a hidden chat takes the last one listed (the sensor reads only shown chats). Without
    // the field every chat keeps ROWS / 2 turns.
    const seed = async (page: Page, slot = Number.MAX_SAFE_INTEGER) => {
      const wanted = sceneTurns(TRANSCRIPT_EVENTS, slot, Math.max(1, Math.round(ROWS / 2)));
      const turns = Math.min(wanted, SEED_TURNS_MAX);
      if (turns < wanted) report.seed_capped = { wanted, seeded: turns };
      const seeded = (await page.evaluate(
        ([count, light]) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light }),
        [turns, !FULL_SEED] as const,
      )) as Record<string, any>;
      report.seed_turns = [...((report.seed_turns as number[] | undefined) ?? []), turns];
      if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
      await page.locator(PROMPT).first().waitFor({ timeout: 60_000 });
    };
    await seed(focused, 0);
    await focused.bringToFront();
    const items: Item[] = [{ page: focused, cdp: await context.newCDPSession(focused), awake: true }];
    await items[0]!.cdp.send("Performance.enable");
    // A tab beside the focused chat, opened in front so it loads as a chat being opened does; bringing the focused
    // chat back to front then hides it as the app's WasHidden does.
    const tabPage = async () =>
      (
        await Promise.all([
          context.waitForEvent("page"),
          browserCdp.send("Target.createTarget", { url: "about:blank" }),
        ])
      )[0];
    const hasChurn = await focused.evaluate(() => typeof (window as any).cmuxAcpmuxDebug.sessionChurn === "function");
    report.churn = hasChurn;
    const add = async (index: number, kind: "chats" | "tabs" = axis) => {
      let page: Page;
      if (kind === "chats") {
        // Same site, so --process-per-site keeps it in the focused chat's renderer.
        page = await tabPage();
        await page.goto(url);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, {
          timeout: 60_000,
        });
        await seed(page);
      } else {
        page = await tabPage();
        await page.goto(`http://t${index}.test:${site.port}/`);
      }
      const cdp = await context.newCDPSession(page);
      await cdp.send("Performance.enable");
      await focused.bringToFront();
      const [state, frames] = await visibility(page);
      if (state !== "hidden" || frames > 0)
        throw new Error(`sim-ladder: ${kind} #${index} reads ${state} at ${frames} frames, not hidden`);
      if (FREEZE) await cdp.send("Page.setWebLifecycleState", { state: "frozen" }).catch(() => undefined);
      items.push({ page, cdp, awake: !FREEZE });
      if (CHURN_HIDDEN && kind === "chats" && hasChurn)
        void page
          .evaluate((o) => (window as any).cmuxAcpmuxDebug.sessionChurn(o), { seconds: 3600, changes_per_second: RATE })
          .catch(() => undefined);
    };
    const startChurn = (rate: number) => {
      if (hasChurn && !churn)
        churn = focused
          .evaluate((o) => (window as any).cmuxAcpmuxDebug.sessionChurn(o), {
            seconds: 3600,
            changes_per_second: rate,
            start_every: 10,
          })
          .catch(() => undefined);
    };
    if (mix) {
      for (let index = 1; index < mix.chats - (mix.visible - 1); index += 1) await add(index, "chats");
      // Tabs before the other windows: a new target opens in the newest window, which focusing the chat would not hide.
      for (let index = 0; index < mix.tabs; index += 1) await add(index, "tabs");
      // The other shown chats: a window each, as the app shows chats side by side; same site, same renderer.
      const shown: Page[] = [focused];
      for (let index = 1; index < mix.visible; index += 1) {
        const [page] = await Promise.all([
          context.waitForEvent("page"),
          browserCdp.send("Target.createTarget", { url: "about:blank", newWindow: true }),
        ]);
        await page.goto(url);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        await seed(page, index);
        const cdp = await context.newCDPSession(page);
        await cdp.send("Performance.enable");
        items.push({ page, cdp, awake: true });
        shown.push(page);
      }
      // Every chat shares one renderer (--process-per-site): the app's agent renderer, the largest (a tab's holds one page).
      const agentPid = renderers(rootPid).sort((a, b) => rssMB(b) - rssMB(a))[0]!;
      await focused.bringToFront();
      startChurn(RATE);
      const states = await Promise.all(shown.map((page) => visibility(page)));
      console.log(`SIM-FIDELITY shown chats ${states.map(([state, frames]) => `${state} ${frames}`).join(", ")}`);
      const hogs = Array.from({ length: mix.hogs }, () => Bun.spawn(["yes"], { stdout: "ignore" }));
      // Each shown chat streams a reply (text deltas, a tool call every 60) through the settle and the window.
      const streams =
        mix.streamMs === null
          ? []
          : shown.map((page) =>
              page
                .evaluate((o) => (window as any).cmuxAcpmuxDebug.loadRun(o), {
                  seconds: Math.ceil((SETTLE_MS + WINDOW_MS) / 1000) + 15,
                  chunk_ms: mix.streamMs,
                  scroll_speed: 0,
                })
                .catch((error: unknown) => ({ error: String(error) })),
            );
      try {
        const sample = await measure(rootPid, items, focused, browserCdp);
        return {
          sample,
          agentRssMB: Math.round(rssMB(agentPid)),
          churn: hasChurn,
        };
      } finally {
        await Promise.all(streams);
        for (const hog of hogs) hog.kill();
        await Promise.all(hogs.map((hog) => hog.exited));
      }
    }
    // The chats axis counts the focused chat as the first; the tabs axis counts tabs beside it.
    let count = axis === "chats" ? 1 : 0;
    for (const rung of RUNGS) {
      while (count < rung) await add(count++);
      await focused.bringToFront();
      startChurn(RATE);
      samples[rung] = await measure(rootPid, items, focused, browserCdp, axis === "chats");
      loadMs[`${axis}.${rung}`] = lastLoadMs;
      ses[rung] = lastSe;
      cycleCounts[rung] = lastCycles;
      console.log(
        `SIM-LADDER ${axis} x${rung} ${JSON.stringify(samples[rung])} renderers ${renderers(rootPid).length}`,
      );
    }
    if (TIMER_CENSUS) {
      const total: Record<string, number> = {};
      for (const item of items.slice(1)) {
        const counts = (await item.page.evaluate(() => (globalThis as any).__slTimers ?? {})) as Record<string, number>;
        for (const [key, n] of Object.entries(counts)) total[key] = (total[key] ?? 0) + n;
      }
      for (const [key, n] of Object.entries(total)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 15))
        console.log(`SIM-LADDER   timers ${n} ${key}`);
    }
    const [focusedState, focusedFrames] = await visibility(focused);
    report[`${axis}_focused`] = `${focusedState} ${focusedFrames}`;
  } finally {
    await chrome.close();
  }
  report[axis] = samples;
  report[`${axis}_se`] = Object.fromEntries(
    RUNGS.map((rung) => [
      rung,
      Object.fromEntries(Object.entries(ses[rung] ?? {}).map(([k, v]) => [k, Math.round(v * 10) / 10])),
    ]),
  );
  report[`${axis}_gc_cycles`] = Object.fromEntries(RUNGS.map((rung) => [rung, cycleCounts[rung] ?? null]));
  for (const metric of [...Object.keys(FLOOR), "frame_p95_ms"] as Metric[]) {
    const values = RUNGS.map((rung) => samples[rung]![metric]);
    // The CPU and script readings carry their standard error (whole cycles, or a rung's windows) where the run had one
    // at every rung; the rest are one reading after a collection.
    const se = RUNGS.every((rung) => ses[rung]?.[metric] !== undefined)
      ? RUNGS.map((rung) => ses[rung]![metric]!)
      : undefined;
    const ratio = Math.round(marginalRatio(metric, RUNGS, values) * 100) / 100;
    ratios[`${axis}.${metric}`] = ratio;
    const low = (values[1]! - values[0]!) / (RUNGS[1]! - RUNGS[0]!);
    const high = (values[2]! - values[1]!) / (RUNGS[2]! - RUNGS[1]!);
    const ci = se && metric !== "frame_p95_ms" ? ratioInterval(metric, RUNGS, values, se) : undefined;
    const r2 = (n: number) => Math.round(n * 100) / 100;
    console.log(
      `SIM-LADDER ${axis} ${metric} ${values.join(" / ")} | per item ${low.toFixed(2)} then ${high.toFixed(2)} | ratio ${ratio}` +
        (ci
          ? ` | per item +-${SIGMAS} se ${ci.low.toFixed(2)} +- ${(SIGMAS * ci.lowSe).toFixed(2)} then ${ci.high.toFixed(2)} +- ${(SIGMAS * ci.highSe).toFixed(2)}, floor ${ci.floor}, ratio in ${r2(ci.lo)} .. ${r2(ci.hi)}`
          : ""),
    );
    if (ci)
      perfRow({
        name: `sim_ladder.${axis}.${metric}.ratio_ci`,
        p50: r2(ci.lo),
        p95: r2(ci.hi),
        unit: "x",
        version: VERSION,
      });
    perfRow({
      name: `sim_ladder.${axis}.${metric}.ratio`,
      p95: ratio,
      unit: "x",
      target: 1.2,
      floor: 0.1,
      version: VERSION,
    });
  }
}

/// The fidelity mode: one scene at the profile, each metric's divergence max(sim/app, app/sim); a pair either side
/// cannot measure reads null with its reason.
async function runProfile() {
  const chats = Math.max(1, fromProfile("agent_total", "agent_pages") ?? 1);
  const visible = Math.min(chats, Math.max(1, fromProfile("agent_visible") ?? 1));
  // The app's events spread over its running chats; a shown chat streams its share: a delta every running/events s.
  const events = fromProfile("events_per_s");
  const running = fromProfile("running_sessions", "running");
  const streamMs =
    events !== null && events > 0
      ? Math.min(1000, Math.max(4, Math.round((1000 * Math.max(1, running ?? 1)) / events)))
      : null;
  const tabs = fromProfile("browser_tabs") ?? 0;
  const load = fromProfile("load_1m", "load1");
  const appCores = fromProfile("cores", "ncpu");
  const cores = os.cpus().length;
  const hogs =
    HOGS !== undefined
      ? Number(HOGS)
      : load !== null && appCores
        ? Math.min(cores, Math.round(Math.max(0, load / appCores - 1) * cores))
        : 0;
  report.profile = {
    file: PROFILE_FILE,
    chats,
    visible,
    tabs,
    stream_ms: streamMs,
    sessions: SESSIONS,
    transcript_events: TRANSCRIPT_EVENTS,
    rate: RATE,
    hogs,
  };
  console.log(`SIM-FIDELITY scene ${JSON.stringify(report.profile)}`);
  const scene = (await runAxis("chats", { chats, visible, tabs, hogs, streamMs }))!;
  console.log(`SIM-FIDELITY sim ${JSON.stringify(scene)}`);
  const longTasks = fromProfile("long_tasks_ms_per_10s");
  const appCpu = fromProfile("renderer_cpu_pct");
  // `extra` pairs are reported beside the goal's four and stay out of the max.
  const pairs: Record<string, { sim: number | null; app: number | null; why?: string; extra?: boolean }> = {
    frame_p95_ms: {
      sim: scene.sample.frame_p95_ms,
      app: fromProfile("frame_p95_ms"),
    },
    keydown_p95_ms: {
      sim: null,
      app: fromProfile("keydown_p95_ms", "keydown_to_frame_p95_ms"),
      why: "UNMEASURED: the app has no passive keydown-to-frame read, and the sim types nothing without one to match",
    },
    script_ms_per_s: {
      sim: scene.sample.script_ms_per_s,
      app: fromProfile("script_ms_per_s"),
      why:
        longTasks !== null
          ? `UNMEASURED: the app's profile gives long frames (${longTasks} ms per 10 s), not script time`
          : "UNMEASURED: the app's profile gives no script time",
    },
    renderer_rss_mb: {
      sim: scene.agentRssMB,
      app: fromProfile("renderer_rss_mb", "agent_renderer_rss_mb"),
    },
    renderer_cpu_ms_per_s: {
      sim: scene.sample.cpu_ms_per_s,
      app: appCpu === null ? null : Math.round(appCpu * 10),
      extra: true,
    },
  };
  const divergences: Record<string, number | null> = {};
  for (const [metric, pair] of Object.entries(pairs)) {
    const measured = pair.sim !== null && pair.app !== null && pair.sim > 0 && pair.app > 0;
    const value = measured ? Math.round(Math.max(pair.sim! / pair.app!, pair.app! / pair.sim!) * 100) / 100 : null;
    divergences[metric] = value;
    console.log(
      `SIM-FIDELITY ${metric} sim ${pair.sim} app ${pair.app} divergence ${value ?? pair.why ?? "UNMEASURED"}`,
    );
    if (value !== null && !pair.extra)
      perfRow({
        name: `sim_fidelity.${metric}.divergence`,
        p95: value,
        unit: "x",
        target: 1.5,
        floor: 0.1,
        version: VERSION,
      });
  }
  report.pairs = pairs;
  report.divergences = divergences;
  report.churn = scene.churn;
  const worst = Object.entries(divergences)
    .filter(([metric]) => !pairs[metric]!.extra)
    .filter((entry): entry is [string, number] => entry[1] !== null)
    .sort((a, b) => b[1] - a[1])[0];
  report.divergence_max = worst?.[1] ?? null;
  report.worst = worst?.[0] ?? null;
  console.log(`SIM-FIDELITY divergence_max ${worst?.[1]} (${worst?.[0]})`);
  if (worst)
    perfRow({
      name: "sim_fidelity.divergence_max",
      p95: worst[1],
      unit: "x",
      target: 1.5,
      floor: 0.1,
      version: VERSION,
    });
}

try {
  if (PROFILE) await runProfile();
  else for (const axis of AXES) await runAxis(axis);
  const worst = PROFILE ? undefined : Object.entries(ratios).sort((a, b) => b[1] - a[1])[0];
  if (!PROFILE) report.ratios = ratios;
  if (!PROFILE) {
    report.ratio_max = worst?.[1] ?? null;
    report.worst = worst?.[0] ?? null;
  }
  // CI keeps only the last lines of a run's log, so the per-rung numbers are printed again here, last: every rung of every
  // axis with its load collection.
  if (!PROFILE) {
    report.load_collection_ms = loadMs;
    for (const axis of AXES)
      for (const rung of RUNGS) {
        const x = (report[axis] as Record<number, Sample> | undefined)?.[rung];
        if (x)
          console.log(
            `SIM-LADDER-SUMMARY ${axis} x${rung} cpu_window ${x.cpu_window_ms_per_s} cpu ${x.cpu_ms_per_s} pss ${x.pss_mb} heap ${x.heap_mb} load_collection ${loadMs[`${axis}.${rung}`]} ms`,
          );
      }
  }
  if (!PROFILE) console.log(`SIM-LADDER ratio_max ${worst?.[1]} (${worst?.[0]})`);
  if (worst)
    perfRow({
      name: "sim_ladder.ratio_max",
      p95: worst[1],
      unit: "x",
      target: 1.2,
      floor: 0.1,
      version: VERSION,
    });
  console.log(`SIM-LADDER-JSON ${JSON.stringify(report)}`);
  if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2));
} finally {
  for (const release of releases) await release();
}
