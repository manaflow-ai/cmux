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
//   cpu_ms_per_s     every renderer's CPU (utime + stime from /proc), ms per second of wall time
//   script_ms_per_s  the awake pages' main-thread script time (CDP Performance.getMetrics ScriptDuration), ms per s
//   pss_mb           every renderer's proportional set size (/proc/PID/smaps_rollup), MB
//   frame_p95_ms     the focused chat's frame intervals (rAF), p95
// The judged number is the marginal ratio: (cost(top) - cost(mid)) / (top - mid) over (cost(mid) - cost(low)) / (mid -
// low), per axis and metric, with a per-item noise floor (FLOOR) under both: flat is 1.0, a per-item cost that grows
// with the count reads above it. Frame p95 is no sum of items, so its ratio is p95(top) / max(p95(mid), 16.7 ms).
// sim_ladder.ratio_max is the worst; cmuxterm-hq's NOW reads it as benches.rows[key=sim_ladder_marginal_ratio_max].
//   bun bench/sim-ladder.bench.ts [--axes chats,tabs] [--rungs 1,10,100] [--sessions 3000] [--rows 120]
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
const RUNGS = (flag("--rungs") ?? "1,10,100")
  .split(",")
  .map(Number)
  .sort((a, b) => a - b);
const SESSIONS = Number(flag("--sessions") ?? 3000);
const ROWS = Number(flag("--rows") ?? 120);
const WINDOW_MS = Number(flag("--window") ?? 5000);
const RATE = Number(flag("--rate") ?? 20);
const FREEZE = argv.includes("--freeze");
const SETTLE_MS = Number(flag("--settle") ?? 20_000);
// Extra Chrome switches, comma-separated (e.g. --disable-features=IntensiveWakeUpThrottling), for experiments.
const CHROME_ARGS = (flag("--chrome-args") ?? "").split(",").filter(Boolean);
// --timer-census: count every timer callback a page runs, by the frame that scheduled it, and print the hidden pages'
// top sources after the last rung (what a hidden chat wakes for).
const TIMER_CENSUS = argv.includes("--timer-census");
const JSON_OUT = flag("--json");
const DIR = flag("--dir") ?? path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const VERSION = 3;
if (RUNGS.length !== 3 || RUNGS.some((n) => !Number.isInteger(n) || n < 1) || RUNGS[0] === RUNGS[1]) {
  console.error("usage: --rungs LOW,MID,TOP (three distinct counts, e.g. 1,10,100)");
  process.exit(2);
}
if (process.platform !== "linux") {
  console.error("sim-ladder: Linux only (renderer CPU and memory from /proc)");
  process.exit(2);
}

const ticksPerSecond = 100; // USER_HZ on every Linux the runners have.
function childrenOf(root: number): Map<number, number[]> {
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
  const children = childrenOf(root);
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
async function launchChrome(): Promise<{ browser: Browser; close: () => Promise<void> }> {
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
      "--disable-features=IntensiveWakeUpThrottling",
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

async function measure(rootPid: number, items: Item[], focused: Page): Promise<Sample> {
  const settled = await settle(rootPid, focused);
  if (!settled) console.log(`SIM-LADDER   not settled in ${SETTLE_MS} ms`);
  const pids = renderers(rootPid);
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
  return {
    cpu_ms_per_s: Math.round(Math.min(...thirds)),
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

async function runAxis(axis: "chats" | "tabs") {
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
    await context.addInitScript((size) => {
      (globalThis as any).cmuxAcpmuxMockListSize = size;
    }, SESSIONS);
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
            const key = `${name} ${rest[0] ?? 0}ms ${site()}`;
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
    await focused.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seed = async (page: Page) => {
      const seeded = (await page.evaluate(
        (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
        Math.max(1, Math.round(ROWS / 2)),
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
    const add = async (index: number) => {
      let page: Page;
      if (axis === "chats") {
        // Same site, so --process-per-site keeps it in the focused chat's renderer.
        page = await tabPage();
        await page.goto(url);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
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
        throw new Error(`sim-ladder: ${axis} #${index} reads ${state} at ${frames} frames, not hidden`);
      if (FREEZE) await cdp.send("Page.setWebLifecycleState", { state: "frozen" }).catch(() => undefined);
      items.push({ page, cdp, awake: !FREEZE });
    };
    // The chats axis counts the focused chat as the first; the tabs axis counts tabs beside it.
    let count = axis === "chats" ? 1 : 0;
    for (const rung of RUNGS) {
      while (count < rung) await add(count++);
      await focused.bringToFront();
      if (hasChurn && !churn)
        churn = focused
          .evaluate((o) => (window as any).cmuxAcpmuxDebug.sessionChurn(o), {
            seconds: 3600,
            changes_per_second: RATE,
            start_every: 10,
          })
          .catch(() => undefined);
      samples[rung] = await measure(rootPid, items, focused);
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

try {
  for (const axis of AXES) await runAxis(axis);
  const worst = Object.entries(ratios).sort((a, b) => b[1] - a[1])[0];
  report.ratios = ratios;
  report.ratio_max = worst?.[1] ?? null;
  report.worst = worst?.[0] ?? null;
  console.log(`SIM-LADDER ratio_max ${worst?.[1]} (${worst?.[0]})`);
  if (worst)
    perfRow({ name: "sim_ladder.ratio_max", p95: worst[1], unit: "x", target: 1.2, floor: 0.1, version: VERSION });
  console.log(`SIM-LADDER-JSON ${JSON.stringify(report)}`);
  if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2));
} finally {
  for (const release of releases) await release();
}
