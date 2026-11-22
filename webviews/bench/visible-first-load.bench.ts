// l10n-allow-file: benchmark output, not shipped UI.
// The focused chat under heavy load: does what the person sees and types into stay smooth while the rest of
// the Mac works? Leo, 2026-11-22: "i think visually there's sometimes still more to be desired maybe esp at
// heavy load. aka right now for some reason. all things slow down, and i think the interactive/visible parts
// of cmux are not prioritized enough, potentially."
//
// The load is what his Mac had when he said it (load average 95 to 185, about 3,000 listed chats, agents
// busy): CPU hogs on every core, and CHATS agent pages in one renderer (the Mac's agent pages share one,
// CEFSwitches processPerSitePageSchemes), each listing SESSIONS chats while other chats change and start
// (cmuxAcpmuxDebug.sessionChurn). In the focused page, the one the person looks at, it measures:
//   keys:   keydown to the next frame (to_frame) and to the page's first listener (to_listener), typing
//   scroll: the frame intervals while the transcript scrolls by wheel
//   frames: the frame intervals while nothing is asked of the page but the churn runs (what Leo watches)
//   main:   main-thread task and script ms per second, all agent pages and the focused one (CDP metrics)
// Each phase is measured idle (no hogs, no churn) and loaded. The row this bench is judged by is
// loaded keys to_frame p95.
//   bun bench/visible-first-load.bench.ts [--chats 4] [--sessions 3000] [--hogs N] [--rate 20] [--start-every 10]
//     [--seeded 2] [--keys 60] [--gap 90] [--rows 600] [--json out.json] [--profile] [--unminified]
// Before and after a change, on one harness: bench/visible-first-load-ab.sh BASE.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const CHATS = Number(flag("--chats") ?? 4);
const SESSIONS = Number(flag("--sessions") ?? 3000);
const HOGS = Number(flag("--hogs") ?? os.cpus().length);
const RATE = Number(flag("--rate") ?? 20);
const START_EVERY = Number(flag("--start-every") ?? 10);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 90);
const ROWS = Number(flag("--rows") ?? 600);
const SEEDED = Math.min(CHATS, Number(flag("--seeded") ?? 2));
const JSON_OUT = flag("--json");
const PROFILE = argv.includes("--profile");
const DIR = flag("--dir") ?? path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";

type Stats = { n: number; p50: number | null; p95: number | null; max: number | null };
const stats = (xs: number[]): Stats => {
  const s = [...xs].sort((a, b) => a - b);
  const q = (p: number) =>
    s.length ? Math.round(s[Math.min(s.length - 1, Math.floor((s.length - 1) * p))]! * 10) / 10 : null;
  return { n: s.length, p50: q(0.5), p95: q(0.95), max: s.length ? Math.round(s.at(-1)! * 10) / 10 : null };
};

/// Frame intervals in `page` for `ms`, while `during` runs.
async function frameIntervals(page: Page, ms: number, during?: () => Promise<unknown>): Promise<number[]> {
  await page.evaluate(() => {
    const w = window as any;
    w.__vfFrames = [];
    w.__vfOn = true;
    let last = performance.now();
    const tick = (now: number) => {
      if (!w.__vfOn) return;
      w.__vfFrames.push(now - last);
      last = now;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame((now) => {
      last = now;
      requestAnimationFrame(tick);
    });
  });
  await Promise.all([page.waitForTimeout(ms), during?.()]);
  return page.evaluate(() => {
    const w = window as any;
    w.__vfOn = false;
    return w.__vfFrames as number[];
  });
}

/// `--profile`: the focused page's 15 heaviest functions by self time in the loaded phase.
function printTop(profile: { nodes: any[]; samples: number[]; timeDeltas: number[] }) {
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const self = new Map<string, number>();
  profile.samples.forEach((id, i) => {
    const f = byId.get(id)!.callFrame;
    const name = `${f.functionName || "(anon)"} ${String(f.url).split("/").pop()}:${f.lineNumber}`;
    self.set(name, (self.get(name) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000);
  });
  for (const [name, ms] of Array.from(self)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 15))
    console.log(`VISIBLE-FIRST-PROFILE ${Math.round(ms)} ms ${name}`);
}

const hogs: ReturnType<typeof Bun.spawn>[] = [];
function startHogs(count: number) {
  for (let i = 0; i < count; i += 1)
    hogs.push(Bun.spawn(["bun", "-e", "let x = 0; for (;;) x = (x + Math.sqrt(x + 1)) % 1e9;"], { stdout: "ignore" }));
}
function stopHogs() {
  for (const hog of hogs.splice(0)) hog.kill();
}

const releases: (() => unknown)[] = [];
const port = await servePane(DIR, { unminified: argv.includes("--unminified") }, releases);
const browser = await chromium.launch({ headless: true, args: ["--process-per-site", "--renderer-process-limit=1"] });
const report: Record<string, unknown> = {
  chats: CHATS,
  seeded: SEEDED,
  sessions: SESSIONS,
  hogs: HOGS,
  rate: RATE,
  start_every: START_EVERY,
  keys: KEYS,
  gap: GAP_MS,
  rows: ROWS,
  cores: os.cpus().length,
};
try {
  const context = await browser.newContext({ viewport: { width: 1100, height: 820 } });
  await context.addInitScript((size) => {
    (globalThis as any).cmuxAcpmuxMockListSize = size;
  }, SESSIONS);
  // One renderer for every page, as the Mac's agent pages share one (--renderer-process-limit=1, and
  // each page after the first opened by the first, so it keeps an opener). Pages
  // past SEEDED are spares, as the Mac keeps: listening to the list, showing no chat.
  const pages: Page[] = [];
  const url = `http://127.0.0.1:${port}/?mock`;
  for (let i = 0; i < CHATS; i += 1) {
    let page: Page;
    if (i === 0) {
      page = await context.newPage();
      await page.goto(url);
    } else {
      [page] = await Promise.all([context.waitForEvent("page"), pages[0]!.evaluate((u) => void window.open(u), url)]);
      await page.waitForLoadState();
    }
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    if (i < SEEDED) {
      const seeded = (await page.evaluate(
        (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
        Math.round(ROWS / 3),
      )) as Record<string, any>;
      if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
      await page.locator(PROMPT).first().waitFor({ timeout: 30_000 });
    }
    pages.push(page);
  }
  const browserCdp = await browser.newBrowserCDPSession();
  const processes: { processInfo: { type: string }[] } = await (browserCdp as any).send("SystemInfo.getProcessInfo");
  const renderers = processes.processInfo.filter((info) => info.type === "renderer").length;
  report.renderers = renderers;
  console.log(`VISIBLE-FIRST renderers ${renderers} for ${CHATS} pages (${SEEDED} chats, the rest spares)`);
  const focused = pages[0]!;
  await focused.bringToFront();
  const missing = await focused.evaluate(() => typeof (window as any).cmuxAcpmuxDebug.sessionChurn !== "function");
  if (missing)
    throw new Error("this pane has no cmuxAcpmuxDebug.sessionChurn (run the A/B script, which adds it to the base)");

  const typing = async () => {
    await focused.locator(PROMPT).first().click();
    for (let i = 0; i < 4; i += 1) await focused.keyboard.press("Backspace");
    await focused.waitForTimeout(200);
    await focused.evaluate(() => (window as any).cmuxAcpmuxDebug.resetTyping());
    for (let i = 0; i < KEYS; i += 1) {
      await focused.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]!);
      await focused.waitForTimeout(GAP_MS);
    }
    await focused.waitForTimeout(300);
    const t = (await focused.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as Record<string, any>;
    for (let i = 0; i < KEYS; i += 1) await focused.keyboard.press("Backspace");
    return { to_frame: t.to_frame, to_listener: t.to_listener, to_work: t.to_work, keys: t.keys };
  };
  const scroll = async () => {
    const box = await focused.locator(".acpmux-scroll").first().boundingBox();
    if (!box) throw new Error("no transcript to scroll");
    await focused.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const wheel = async () => {
      for (let i = 0; i < 60; i += 1) {
        await focused.mouse.wheel(0, i < 30 ? -120 : 120);
        await focused.waitForTimeout(16);
      }
    };
    return stats(await frameIntervals(focused, 2500, wheel));
  };
  // Main-thread time every agent page spent (CDP Performance.getMetrics), per second of the phase: what the
  // change removes, whatever the host's core count does to frame cadence.
  const cdps = await Promise.all(pages.map((page) => context.newCDPSession(page)));
  await Promise.all(cdps.map((cdp) => cdp.send("Performance.enable")));
  const busy = async () => {
    const all = await Promise.all(cdps.map((cdp) => cdp.send("Performance.getMetrics")));
    const pick = (m: { metrics: { name: string; value: number }[] }, name: string) =>
      m.metrics.find((x) => x.name === name)?.value ?? 0;
    return {
      at: performance.now(),
      task: all.map((m) => pick(m, "TaskDuration")),
      script: all.map((m) => pick(m, "ScriptDuration")),
      style: all.map((m) => pick(m, "RecalcStyleDuration")),
      layout: all.map((m) => pick(m, "LayoutDuration")),
    };
  };
  const perSecond = (a: Awaited<ReturnType<typeof busy>>, b: Awaited<ReturnType<typeof busy>>) => {
    const secs = (b.at - a.at) / 1000;
    const ms = (xs: number[], ys: number[], i?: number) =>
      Math.round(((i === undefined ? ys.reduce((t, y, j) => t + y - xs[j]!, 0) : ys[i]! - xs[i]!) * 1000) / secs);
    return {
      task_ms_per_s: ms(a.task, b.task),
      script_ms_per_s: ms(a.script, b.script),
      focused_task_ms_per_s: ms(a.task, b.task, 0),
      focused_script_ms_per_s: ms(a.script, b.script, 0),
      focused_style_ms_per_s: ms(a.style, b.style, 0),
      focused_layout_ms_per_s: ms(a.layout, b.layout, 0),
    };
  };
  const phase = async (loaded: boolean) => {
    let churn: Promise<unknown>[] = [];
    if (loaded) {
      startHogs(HOGS);
      const seconds = (KEYS * (GAP_MS + 40)) / 1000 + 12;
      churn = pages.map((page) =>
        page.evaluate((o) => (window as any).cmuxAcpmuxDebug.sessionChurn(o), {
          seconds,
          changes_per_second: RATE,
          start_every: START_EVERY,
        }),
      );
      await focused.waitForTimeout(1500);
    }
    try {
      const from = await busy();
      if (PROFILE && loaded) await cdps[0]!.send("Profiler.enable").then(() => cdps[0]!.send("Profiler.start"));
      const frames = stats(await frameIntervals(focused, 3000));
      const keys = await typing();
      const scrolled = await scroll();
      const main = perSecond(from, await busy());
      if (PROFILE && loaded) printTop((await cdps[0]!.send("Profiler.stop")).profile as any);
      return { frames, keys, scroll: scrolled, main, churn: loaded ? await Promise.all(churn) : null };
    } finally {
      stopHogs();
    }
  };
  report.idle = await phase(false);
  report.loaded = await phase(true);
  const row = (label: string, r: any) =>
    console.log(
      `VISIBLE-FIRST ${label} keys.to_frame p50 ${r.keys.to_frame?.p50_ms} p95 ${r.keys.to_frame?.p95_ms} max ${r.keys.to_frame?.max_ms}` +
        ` | to_listener p95 ${r.keys.to_listener?.p95_ms} | scroll frame p50 ${r.scroll.p50} p95 ${r.scroll.p95} max ${r.scroll.max}` +
        ` | idle-watch frame p95 ${r.frames.p95} max ${r.frames.max}` +
        ` | main-thread all pages task ${r.main.task_ms_per_s} script ${r.main.script_ms_per_s} ms/s, focused task ${r.main.focused_task_ms_per_s} script ${r.main.focused_script_ms_per_s} style ${r.main.focused_style_ms_per_s} layout ${r.main.focused_layout_ms_per_s} ms/s`,
    );
  row("idle", report.idle);
  row("loaded", report.loaded);
  console.log(`VISIBLE-FIRST-JSON ${JSON.stringify(report)}`);
  if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2));
} finally {
  stopHogs();
  await browser.close();
  for (const release of releases) await release();
}
