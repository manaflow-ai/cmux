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
//                    window's thirds (other load on a shared runner only adds CPU)
//   cpu_window_ms_per_s  the same over the whole window: a GC burst in one third shows here, where the least hides it
//                    (chats x100 read 1337 ms/s over the window, ThreadPoolForeg 1137, while the least read flat)
//   heap_mb          the renderers' JS heap after a full collection (the chats share one isolate), MB
//   script_ms_per_s  the awake pages' main-thread script time (CDP Performance.getMetrics ScriptDuration), ms per s
//   pss_mb           every renderer's proportional set size (/proc/PID/smaps_rollup), MB
//   frame_p95_ms     the focused chat's frame intervals (rAF), p95
// The judged number is the marginal ratio: (cost(top) - cost(mid)) / (top - mid) over (cost(mid) - cost(low)) / (mid -
// low), per axis and metric, with a per-item noise floor (FLOOR) under both: flat is 1.0, a per-item cost that grows
// with the count reads above it. Frame p95 is no sum of items, so its ratio is p95(top) / max(p95(mid), 16.7 ms).
// sim_ladder.ratio_max is the worst; cmuxterm-hq's NOW reads it as benches.rows[key=sim_ladder_marginal_ratio_max].
//   bun bench/sim-ladder.bench.ts [--axes chats,tabs] [--rungs 10,50,100] [--sessions 3000] [--rows 120]
//     [--window 5000] [--settle 20000] [--rate 20] [--freeze] [--json out.json]
// Hidden means Chromium's own hidden state (CEF's WasHidden: no frames, no compositor, visibilityState "hidden"), not a
// script override: each added page is a tab, loaded in front and then put behind the focused chat, of a Chrome this bench
// launches and drives through connectOverCDP with noDefaults, because Playwright's own pages get
// Emulation.setFocusEmulationEnabled, which keeps every page visible and drawing (~2 ms/s each). A page that does not
// read hidden fails the run.
// Linux only (it reads /proc); prints SIM-LADDER lines and PERF_ROW lines (sim_ladder.*).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
import { FLOOR, marginalRatio, type Metric, type Sample } from "./ladderRatio";
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
// --full-seed: seed chats with the mock's full load turns (tool calls, diffs, long replies) instead of light ones. The
// fidelity mode always does: at the 13:03Z NIGHTLY profile light seeds drew frames at 100 ms p95, full ones at 66.6
// against the app's 66.3.
const FULL_SEED = argv.includes("--full-seed") || PROFILE !== undefined;
const WINDOW_MS = Number(flag("--window") ?? 5000);
const changesPerMin = fromProfile("sessions_changed_per_min");
const RATE = Number(flag("--rate") ?? (changesPerMin !== null ? changesPerMin / 60 : 20));
const FREEZE = argv.includes("--freeze");
const SETTLE_MS = Number(flag("--settle") ?? 20_000);
// Extra Chrome switches, comma-separated (e.g. --disable-features=IntensiveWakeUpThrottling), for experiments.
const CHROME_ARGS = (flag("--chrome-args") ?? "").split(",").filter(Boolean);
// --timer-census: count every timer callback a page runs, by the frame that scheduled it, and print the hidden pages'
// top sources after the last rung (what a hidden chat wakes for).
const TIMER_CENSUS = argv.includes("--timer-census");
const JSON_OUT = flag("--json");
// --profile FILE (read above): the fidelity mode. Instead of the ladder, build one scene from a profile of a running app
// (cmux-app-profile, from leo-workspace tools/perf_sensor.py): its agent pages, browser tabs, listed sessions, change
// rate and load, then compare the sim's frame p95, keydown, script ms/s and agent renderer RSS with the app's.
// --hogs N: CPU-bound processes beside the scene while it is measured (the app's machine load). Default: the
// profile's load per core over this machine's cores, at most one per core.
const HOGS = flag("--hogs");
const DIR = flag("--dir") ?? path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const VERSION = 4;
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
/// from stderr: the patched headless shell when CI fetched one, else the installed Chrome headless.
async function launchChrome(): Promise<{
  browser: Browser;
  close: () => Promise<void>;
}> {
  const shell = process.env.CMUX_CHROME_HEADLESS_SHELL;
  const exe = shell || Bun.which("google-chrome") || Bun.which("google-chrome-stable");
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

/// The last rung's load collection (renderer CPU ms), kept for the summary printed at the end.
let lastLoadMs = 0;
const loadMs: Record<string, number> = {};

async function measure(rootPid: number, items: Item[], focused: Page): Promise<Sample> {
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
  const ticks0 = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
  const threads0 = threadTicks(pids);
  const script0 = await script();
  const t0 = performance.now();
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
  // Renderer CPU per third of the window, and the least of the three: other load on the machine only adds CPU, and
  // on a shared runner (load 25-60 on 32 cores) one rung read 681 ms/s for a minute where a quiet rerun read 40.
  // A once-a-second trace over the windows: renderer CPU ms in the second, its ThreadPoolForeground share (V8's parallel GC
  // workers), and the focused isolate's JS heap in MB. A burst that lands with a heap drop is a major collection.
  const trace: string[] = [];
  let tracing = true;
  const sampler = (async () => {
    let lastTicks = ticks0;
    let lastPool = threadTicks(pids).get("ThreadPoolForeg") ?? 0;
    while (tracing) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const nowTicks = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
      const pool = threadTicks(pids).get("ThreadPoolForeg") ?? 0;
      const heapNow = await Promise.race([
        items[0]!.cdp
          .send("Performance.getMetrics")
          .then((m) => Math.round((m.metrics.find((x) => x.name === "JSHeapUsedSize")?.value ?? 0) / 1048576))
          .catch(() => -1),
        new Promise<number>((resolve) => setTimeout(() => resolve(-1), 500)),
      ]);
      trace.push(
        `${Math.round(((nowTicks - lastTicks) / ticksPerSecond) * 1000)}/${Math.round(((pool - lastPool) / ticksPerSecond) * 1000)}/${heapNow}`,
      );
      lastTicks = nowTicks;
      lastPool = pool;
    }
  })();
  const thirds: number[] = [];
  let mark = ticks0;
  let markAt = t0;
  for (let i = 0; i < 3; i += 1) {
    await focused.waitForTimeout(WINDOW_MS / 3);
    const now = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
    const at = performance.now();
    thirds.push((((now - mark) / ticksPerSecond) * 1000) / ((at - markAt) / 1000));
    mark = now;
    markAt = at;
  }
  const frames = (await focused.evaluate(() => {
    const w = window as any;
    w.__slOn = false;
    return w.__slFrames as number[];
  })) as number[];
  const secs = (performance.now() - t0) / 1000;
  const windowMsPerS = (((mark - ticks0) / ticksPerSecond) * 1000) / ((markAt - t0) / 1000);
  console.log(`SIM-LADDER   cpu thirds ms/s ${thirds.map(Math.round).join(", ")} | window ${Math.round(windowMsPerS)}`);
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
  const script1 = await script();
  // The whole-window CPU is the median of three windows (one 5 s window is a sample of one: the x1 window read 22 to
  // 128 ms/s across runs of the same code): a cost that lasts shows in all three, a one-off burst in one.
  const windows = [windowMsPerS];
  for (let i = 1; i < 3; i += 1) {
    const before = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
    const from = performance.now();
    await focused.waitForTimeout(WINDOW_MS);
    const after = pids.reduce((sum, pid) => sum + cpuTicks(pid), 0);
    windows.push((((after - before) / ticksPerSecond) * 1000) / ((performance.now() - from) / 1000));
  }
  tracing = false;
  await sampler;
  console.log(`SIM-LADDER   per-second cpu ms / pool ms / js heap MB: ${trace.join(" ")}`);
  const medianWindow = [...windows].sort((a, b) => a - b)[1]!;
  console.log(
    `SIM-LADDER   cpu windows ms/s ${windows.map(Math.round).join(", ")} | median ${Math.round(medianWindow)}`,
  );
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
    cpu_ms_per_s: Math.round(Math.min(...thirds)),
    cpu_window_ms_per_s: Math.round(medianWindow),
    heap_mb: Math.round(heaps.reduce((sum, bytes) => sum + bytes, 0) / 1048576),
    script_ms_per_s: Math.round(((script1 - script0) * 1000) / secs),
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
    const seed = async (page: Page) => {
      const seeded = (await page.evaluate(
        ([turns, light]) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light }),
        [Math.max(1, Math.round(ROWS / 2)), !FULL_SEED] as const,
      )) as Record<string, any>;
      if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
      await page.locator(PROMPT).first().waitFor({ timeout: 60_000 });
    };
    await seed(focused);
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
        await seed(page);
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
        const sample = await measure(rootPid, items, focused);
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
      samples[rung] = await measure(rootPid, items, focused);
      loadMs[`${axis}.${rung}`] = lastLoadMs;
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
  for (const metric of [...Object.keys(FLOOR), "frame_p95_ms"] as Metric[]) {
    const values = RUNGS.map((rung) => samples[rung]![metric]);
    const ratio = Math.round(marginalRatio(metric, RUNGS, values) * 100) / 100;
    ratios[`${axis}.${metric}`] = ratio;
    const low = (values[1]! - values[0]!) / (RUNGS[1]! - RUNGS[0]!);
    const high = (values[2]! - values[1]!) / (RUNGS[2]! - RUNGS[1]!);
    console.log(
      `SIM-LADDER ${axis} ${metric} ${values.join(" / ")} | per item ${low.toFixed(2)} then ${high.toFixed(2)} | ratio ${ratio}`,
    );
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
