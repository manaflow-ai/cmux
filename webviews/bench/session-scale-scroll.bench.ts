// l10n-allow-file: benchmark output, not shipped UI.
// Scrolling one short chat while the other agent pages in the same renderer hear the daemon's session
// changes, at a fleet's scale. Leo, 2026-11-18: "Lawrence, on a relatively small chat, of course, like this
// is in his app with a lot of workspaces, a lot of history, and he was just scrolling up and down through
// that one particular chat, and you know, he was feeling some dropped frames, like it wasn't smooth. ... it
// gets sort of hijacked by the other parts of the app, which are actually non-visible." Lucas, with a
// sparser history, could not see it at 100% CPU: the cost grows with the chats listed, not with the chat.
//
// The real pane (`?mock`, production React by Vite) in PAGES pages of one Chromium renderer
// (`--renderer-process-limit=1`, as the app runs its agent pages), each with SIZE listed sessions shaped as a
// fleet Mac's (mockFixture.ts `fleetListedSession`). The first page shows a short chat (SHORT turns, two rows
// each); the second a long one no tab shows (LONG turns); the last NEWTABS pages are New Tab pages (a tab's
// New Tab, the prewarmed spare). Every page's mock daemon changes one open listed session RATE times a second
// (mock.ts `changeSession`), PAD bytes of row detail each, as his daemon's rows were. Then the first page's
// transcript is wheeled up and down (STEP px a wheel event, one each GAP ms) for SCROLL_MS. Rows, per size:
//   frame_p50 / frame_p95   intervals between the scrolled page's animation frames, ms
//   dropped                 frames over 16.7 ms (one 60 Hz frame) late, and per second
//   busy_pct                the renderer main thread's task time over the window (CDP TaskDuration), %
//   renders                 each page's counted renders (`cmuxAcpmuxDebug.renders()`) over the window: work a
//                           wheel never asked for (a hidden page's pane, the scrolled page's composer)
//   busy_pct is read under THROTTLE x CPU throttling (CDP), a laptop busy with the rest of the app.
//   bun bench/session-scale-scroll.bench.ts [--sizes 100,10000] [--pages 4] [--newtabs 2] [--rate 4]
//     [--pad 17000] [--short 15] [--long 2000] [--scroll 6000] [--step 60] [--gap 16] [--settle 4000] [--throttle 4]
//     [--profile]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession, Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";
import { requireProductionReact, installReactWatch } from "./support/benchPage";
import { perfRow, TARGET_MS } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "100,10000").split(",").map(Number);
const PAGES = Number(flag("--pages") ?? 4);
const NEWTABS = Number(flag("--newtabs") ?? 2);
const RATE = Number(flag("--rate") ?? 4);
const PAD = Number(flag("--pad") ?? 17_000);
/// Turns of the chat scrolled: about 30 messages.
const SHORT = Number(flag("--short") ?? 15);
/// Turns of the other chat page's chat, which no tab shows.
const LONG = Number(flag("--long") ?? 2000);
const SCROLL_MS = Number(flag("--scroll") ?? 6000);
const STEP = Number(flag("--step") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 16);
const SETTLE_MS = Number(flag("--settle") ?? 4000);
/// CDP CPU throttling of the renderer while it scrolls (1: none).
const THROTTLE = Number(flag("--throttle") ?? 4);
const SHAPE = "fleet" as "fleet" | "plain";
/// mockFixture.ts FLEET_OPEN_EVERY: one fleet row in this many is open.
const OPEN_EVERY = 20;
const PROFILE = argv.includes("--profile");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const FRAME_MS = 1000 / 60;
if (SIZES.some((size) => !Number.isInteger(size) || size < 0) || !(PAGES >= 2) || !(RATE >= 0)) {
  console.error("usage: bun bench/session-scale-scroll.bench.ts [--sizes 100,10000] [--pages 4] [--rate 4]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");

/// In the page: every `1000 / rate` ms one listed session changes (its status flips, and it carries `pad`
/// characters of detail), the way the daemon tells a watcher: one `session_changed` with its summary.
async function installDriver({ size, rate, pad, every }: { size: number; rate: number; pad: number; every: number }) {
  type MockModule = typeof import("../src/agent-session/acpmux/mock");
  const mockUrl = "/mock.ts";
  const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
  const daemon = MockAcpmuxSocket.live;
  if (!daemon) throw new Error("no mock daemon");
  const spans = Array.from({ length: Math.max(0, Math.floor(pad / 120)) }, (_, index) => ({
    turnId: `turn-${index}`,
    startMs: index * 1000,
    endMs: index * 1000 + 900,
    category: index % 3 ? "tool" : "model",
  }));
  let round = 0;
  let timer: ReturnType<typeof setInterval> | undefined;
  (window as any).__scale = {
    start() {
      if (rate <= 0 || size <= 0 || timer) return;
      timer = setInterval(() => {
        round += 1;
        const index = every * Math.floor((Math.random() * size) / every);
        daemon.changeSession(`listed-${index}`, (current: Record<string, any>) => ({
          status: current.status === "running" ? "idle" : "running",
          indicator: current.indicator === "working" ? "done" : "working",
          updatedAt: Date.now(),
          timeBreakdown: { totalMs: round * 1000, totalTokens: round, categories: [], spans },
        }));
      }, 1000 / rate);
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
      return round;
    },
  };
}

/// Init script: every long task from page load.
function probe() {
  const w = window as unknown as { __longTasks?: { at: number; ms: number }[] };
  if (w.__longTasks) return;
  const tasks: { at: number; ms: number }[] = [];
  w.__longTasks = tasks;
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) tasks.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without long tasks reads 0.
  }
}

async function openPage(page: Page, port: number, size: number, newTab: boolean, turns: number) {
  await page.addInitScript(
    ({ count, shape, newTab }) => {
      const mock = globalThis as {
        cmuxAcpmuxMockListSize?: number;
        cmuxAcpmuxMockListShape?: string;
        __cmuxNewTabContext?: unknown;
      };
      mock.cmuxAcpmuxMockListSize = count;
      if (shape === "fleet") mock.cmuxAcpmuxMockListShape = "fleet";
      // The list's row log, as acpmux follows it (hub/row_log.rs): a watch from a position reads the
      // rows changed since.
      (mock as { cmuxAcpmuxMockCapabilities?: string[] }).cmuxAcpmuxMockCapabilities = ["session-list-follow-v1"];
      // A New Tab page as the app opens one (a tab's New Tab, or the prewarmed spare): the host
      // injects its context before the page's first render (newtab/adoption.ts).
      if (newTab) mock.__cmuxNewTabContext = {};
    },
    { count: size, shape: SHAPE, newTab },
  );
  await page.addInitScript(probe);
  await installReactWatch(page);
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 120_000 });
  await requireProductionReact(page, { dev: false });
  if (newTab) {
    // The New Tab screen with its chat lists, as a tab's New Tab or the spare draws it.
    await page
      .locator(".nt-screen")
      .first()
      .waitFor({ state: "attached", timeout: 30_000 })
      .catch(async (error) => {
        const classes = await page.evaluate(() =>
          [...document.querySelectorAll("[class]")]
            .slice(0, 60)
            .map((node) => node.getAttribute("class"))
            .join(" | "),
        );
        throw new Error(`no New Tab screen: ${String(error)}; the page draws ${classes}`);
      });
    await page.evaluate(installDriver, { size, rate: RATE, pad: PAD, every: SHAPE === "fleet" ? OPEN_EVERY : 1 });
    return;
  }
  const seeded = (await page.evaluate(
    (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 60_000 });
  await page.evaluate(installDriver, { size, rate: RATE, pad: PAD, every: SHAPE === "fleet" ? OPEN_EVERY : 1 });
}

const taskMs = async (cdp: CDPSession) => {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((metric) => metric.name === "TaskDuration")!.value * 1000;
};
const round1 = (value: number) => Math.round(value * 10) / 10;

type Profile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples?: number[];
  timeDeltas?: number[];
};
/// --profile: the functions with the most self and inclusive time per second of the typing window, over
/// every page the renderer runs (its pages share one V8 isolate).
function printProfile(profile: Profile, size: number, wallMs: number) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const name = (id: number) => {
    const frame = byId.get(id)!.callFrame;
    const file = frame.url.split("/").slice(-2).join("/").split("?")[0];
    return `${frame.functionName || "(anon)"} ${file}:${frame.lineNumber + 1}`;
  };
  const self = new Map<string, number>();
  const inclusive = new Map<string, number>();
  (profile.samples ?? []).forEach((id, index) => {
    const fn = byId.get(id)?.callFrame.functionName;
    if (fn === "(idle)" || fn === "(program)") return;
    const ms = (profile.timeDeltas?.[index + 1] ?? 0) / 1000;
    self.set(name(id), (self.get(name(id)) ?? 0) + ms);
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const key = name(at);
      if (seen.has(key)) continue;
      seen.add(key);
      inclusive.set(key, (inclusive.get(key) ?? 0) + ms);
    }
  });
  const top = (map: Map<string, number>, count: number) =>
    [...map]
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key, ms]) => `  ${((ms * 1000) / wallMs).toFixed(1).padStart(7)} ms/s  ${key}`)
      .join("\n");
  console.log(`PROFILE n=${size} self:\n${top(self, 30)}`);
  console.log(`PROFILE n=${size} inclusive:\n${top(inclusive, 60)}`);
}

process.env.NODE_ENV = "production";
const { createServer } = await import("vite");
const vite = await createServer({
  mode: "production",
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const results: Record<string, unknown>[] = [];
const quantile = (sorted: number[], q: number) =>
  sorted.length === 0 ? 0 : sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
try {
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  const { port } = vite.httpServer!.address() as { port: number };
  for (const size of SIZES) {
    // One renderer for every page, as the app's agent pages share one.
    const browser = await chromium.launch({ headless: true, args: ["--renderer-process-limit=1"] });
    try {
      const context = await browser.newContext({ viewport: { width: 1100, height: 820 } });
      const pages: Page[] = [];
      for (let index = 0; index < PAGES; index += 1) {
        const page = await context.newPage();
        const newTab = index > 0 && index > PAGES - 1 - NEWTABS;
        await openPage(page, port, size, newTab, index === 0 ? SHORT : LONG);
        pages.push(page);
      }
      const shown = pages[0]!;
      await shown.bringToFront();
      const cdp = await context.newCDPSession(shown);
      await cdp.send("Performance.enable");
      // A laptop busy with everything else his app runs: the renderer's main thread THROTTLE times slower.
      if (THROTTLE > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE });
      const scroller = shown.locator(".acpmux-scroll").first();
      await scroller.waitFor({ timeout: 60_000 });
      const box = (await scroller.boundingBox())!;
      await shown.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      const range = await shown.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return node.scrollHeight - node.clientHeight;
      });
      if (range < STEP * 4) throw new Error(`scroll bench: the chat scrolls only ${range} px; raise --short`);
      // The pages nobody sees (the chat no tab shows, the New Tab pages: a tab's behind another and the
      // spare off screen), told so as the app's host tells them once they painted
      // (AgentPaneShownPushes.swift `AgentPageSeenSignal`). A build before the switch ignores it.
      for (const page of pages.slice(1)) await page.evaluate(() => (window as any).cmuxPageSeen?.(false));
      for (const page of pages) await page.evaluate(() => (window as any).__scale.start());
      // fixed-wait: the change stream reaches its steady state (every page's list and caches warm) first.
      await shown.waitForTimeout(SETTLE_MS);
      // Every page's committed renders from here on (the first call turns counting on and resets it).
      await Promise.all(pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())));
      // `session_changed` notices each page's daemon sent it from here on (mock.ts `deliver`).
      const noticesAt = () =>
        Promise.all(pages.map((page) => page.evaluate(() => Number((window as any).cmuxAcpmuxMockNotices ?? 0))));
      const noticesBefore = await noticesAt();
      await shown.evaluate(() => {
        const w = window as unknown as { __frames: number[]; __framesRun: boolean };
        w.__frames = [];
        w.__framesRun = true;
        const tick = (now: number) => {
          if (!w.__framesRun) return;
          w.__frames.push(now);
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
      const busyBefore = await taskMs(cdp);
      const wallBefore = performance.now();
      if (PROFILE) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
        await cdp.send("Profiler.start");
      }
      // Up through the chat and back down, again and again, a wheel event a frame.
      let direction = -1;
      let moved = 0;
      let wheels = 0;
      while (performance.now() - wallBefore < SCROLL_MS) {
        await shown.mouse.wheel(0, direction * STEP);
        wheels += 1;
        moved += STEP;
        if (moved >= range) {
          moved = 0;
          direction = -direction;
        }
        await shown.waitForTimeout(GAP_MS);
      }
      const wall = performance.now() - wallBefore;
      const busy = (await taskMs(cdp)) - busyBefore;
      if (PROFILE) printProfile(((await cdp.send("Profiler.stop")) as { profile: Profile }).profile, size, wall);
      const frames = (await shown.evaluate(() => {
        const w = window as unknown as { __frames: number[]; __framesRun: boolean };
        w.__framesRun = false;
        return w.__frames;
      })) as number[];
      const renders = (await Promise.all(
        pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())),
      )) as Record<string, number>[];
      const notices = (await noticesAt()).map((count, index) => count - noticesBefore[index]!);
      // The spare shown (adopted): what it draws in its first 500 ms to catch up on what it missed.
      const spare = pages.at(-1)!;
      await spare.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
      await spare.evaluate(() => (window as any).cmuxPageSeen?.(true));
      await spare.waitForTimeout(500);
      const showRenders = Object.values(
        (await spare.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>,
      ).reduce((sum, count) => sum + count, 0);
      const changes = await Promise.all(pages.map((page) => page.evaluate(() => (window as any).__scale.stop())));
      const gaps = frames.slice(1).map((at, index) => at - frames[index]!);
      const sorted = [...gaps].sort((a, b) => a - b);
      const dropped = gaps.filter((gap) => gap > FRAME_MS * 1.5).length;
      // Renders other than the transcript's own rows, per page: what the wheel should not cost.
      const outside = renders.map((byName) =>
        Object.entries(byName)
          .filter(([name]) => !/^(row|frame|content|tool|tool-mount|mount|remount):/.test(name))
          .reduce((sum, [, count]) => sum + count, 0),
      );
      const row = {
        size,
        pages: PAGES,
        newtabs: NEWTABS,
        rate: RATE,
        wheels,
        frames: gaps.length,
        frame_p50: round1(quantile(sorted, 0.5)),
        frame_p95: round1(quantile(sorted, 0.95)),
        frame_max: round1(sorted.at(-1) ?? 0),
        dropped,
        dropped_per_s: round1((dropped * 1000) / wall),
        busy_pct: round1((busy / wall) * 100),
        outside_renders: outside,
        notices,
        spare_show_renders: showRenders,
        changes: changes.reduce((sum, value) => sum + value, 0),
      };
      results.push(row);
      console.log(
        `n=${size} pages=${PAGES} (${NEWTABS} new tab) rate=${RATE}/s: frame p50 ${row.frame_p50} p95 ${row.frame_p95} ` +
          `max ${row.frame_max} ms, dropped ${row.dropped} (${row.dropped_per_s}/s), main thread busy ${row.busy_pct} %, ` +
          `renders outside the transcript per page ${outside.join("/")}, session_changed per page ${notices.join("/")}, ` +
          `spare renders on show ${showRenders}`,
      );
      renders.forEach((byName, index) => {
        const top = Object.entries(byName)
          .sort((a, b) => b[1] - a[1])
          .slice(0, 12)
          .map(([name, count]) => `${name} ${count}`);
        console.log(`RENDERS n=${size} page ${index}: ${top.join(", ")}`);
      });
      perfRow({
        name: `session_scale_scroll.frame.n${size}`,
        p50: row.frame_p50,
        p95: row.frame_p95,
        target: TARGET_MS.frameWork,
      });
      await context.close();
    } finally {
      await browser.close();
    }
  }
  console.log(`SESSION-SCALE-SCROLL ${JSON.stringify(results)}`);
} finally {
  await vite.close();
}
