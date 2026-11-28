// l10n-allow-file: benchmark output, not shipped UI.
// Typing in one chat's composer while every agent page in the same renderer hears the daemon's session
// changes, at a fleet's scale (Leo, 2026-11-18, on his NIGHTLY: "typing in the composer still slow 😞 there
// must be a lot of open stuff?"). His Mac's daemon listed 10,789 sessions; its watch sent about 4
// `_acpmux/session_changed` a second, most of them other machines' chats, and one Chromium renderer drew all
// four of his agent pages (two chats on screen, two pages no tab showed), so a key in one composer waited
// behind the frames every page drew for chats nobody looked at.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon, served as production
// React by Vite) in PAGES pages of one Chromium renderer (`--renderer-process-limit=1`, as the app runs its
// agent pages), each with SIZE listed sessions (`cmuxAcpmuxMockListSize`) and a light chat open. Every page's
// mock daemon changes a random listed session RATE times a second (mock.ts `changeSession`), each change
// carrying PAD bytes of row detail, as his daemon's rows did (a chat's `timeBreakdown` spans). Then KEYS
// letters are typed into the first page's composer, GAP ms apart. Rows, per size:
//   to_frame / to_paint  keydown to the next frame / to its paint, p50 and p95 (perf.ts typingStats), ms
//   busy_pct             the renderer main thread's task time over the typing window (CDP TaskDuration), %
//   long_tasks           tasks of 50 ms or more in the first page during the window, and the longest
//   pane_renders_per_change  the pane root's renders (`acpmuxPerf.render("pane")`) per change, per page (the
//                        first page's keys add theirs)
//   bun bench/session-scale-typing.bench.ts [--sizes 100,10000] [--pages 4] [--rate 4] [--pad 17000]
//     [--newtabs 2] [--keys 40] [--gap 80] [--settle 4000] [--shape fleet|plain] [--profile]
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
/// How many of those pages are New Tab pages (the host-injected New Tab context): his two pages no tab showed were a tab's New Tab
/// (`pending_tab_…`) and the prewarmed spare. The first page, the one typed in, is always a chat.
const NEWTABS = Number(flag("--newtabs") ?? 2);
const RATE = Number(flag("--rate") ?? 4);
const PAD = Number(flag("--pad") ?? 17_000);
const KEYS = Number(flag("--keys") ?? 40);
const GAP_MS = Number(flag("--gap") ?? 80);
const SETTLE_MS = Number(flag("--settle") ?? 4000);
/// `fleet` (the default): listed rows shaped as a fleet Mac's (mockFixture.ts `fleetListedSession`), and only its
/// open rows change, as on his; `plain`: the small idle rows of `listedSession`.
const SHAPE = (flag("--shape") ?? "fleet") as "fleet" | "plain";
/// mockFixture.ts FLEET_OPEN_EVERY: one fleet row in this many is open.
const OPEN_EVERY = 20;
const PROFILE = argv.includes("--profile");
/// Turns of the light chat each chat page opens (two rows each): his coordinator chat ran 2,275 turns.
const TURNS = Number(flag("--turns") ?? 2000);
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
if (SIZES.some((size) => !Number.isInteger(size) || size < 0) || !(PAGES >= 1) || !(RATE >= 0) || !(KEYS > 0)) {
  console.error("usage: bun bench/session-scale-typing.bench.ts [--sizes 100,10000] [--pages 4] [--rate 4]");
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

async function openPage(page: Page, port: number, size: number, newTab: boolean) {
  await page.addInitScript(
    ({ count, shape, newTab }) => {
      const mock = globalThis as {
        cmuxAcpmuxMockListSize?: number;
        cmuxAcpmuxMockListShape?: string;
        cmuxAcpmuxMockPaged?: boolean;
        __cmuxNewTabContext?: unknown;
      };
      mock.cmuxAcpmuxMockListSize = count;
      // The list in pages of the client's `limit`, as acpmux sends it (mock.ts `listPage`).
      mock.cmuxAcpmuxMockPaged = true;
      if (shape === "fleet") mock.cmuxAcpmuxMockListShape = "fleet";
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
    TURNS,
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
        await openPage(page, port, size, index > 0 && index > PAGES - 1 - NEWTABS);
        pages.push(page);
      }
      const typing = pages[0]!;
      await typing.bringToFront();
      const cdp = await context.newCDPSession(typing);
      await cdp.send("Performance.enable");
      await typing.locator(PROMPT).first().click();
      for (const key of "warm") await typing.keyboard.press(key);
      for (let i = 0; i < 4; i += 1) await typing.keyboard.press("Backspace");
      for (const page of pages) await page.evaluate(() => (window as any).__scale.start());
      // fixed-wait: the change stream reaches its steady state (every page's list and caches warm) before keys.
      await typing.waitForTimeout(SETTLE_MS);
      await typing.evaluate(() => {
        const debug = (window as any).cmuxAcpmuxDebug;
        debug.resetTyping();
        debug.renders();
      });
      // Every page's committed renders from here on (the first call turns counting on and resets it).
      await Promise.all(pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())));
      const since = await typing.evaluate(() => performance.now());
      const busyBefore = await taskMs(cdp);
      const wallBefore = performance.now();
      if (PROFILE) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
        await cdp.send("Profiler.start");
      }
      const letters = "abcdefghijklmnopqrstuvwxyz";
      for (let i = 0; i < KEYS; i += 1) {
        await typing.keyboard.press(letters[i % letters.length]!);
        await typing.waitForTimeout(GAP_MS);
      }
      const wall = performance.now() - wallBefore;
      const busy = (await taskMs(cdp)) - busyBefore;
      if (PROFILE) printProfile(((await cdp.send("Profiler.stop")) as { profile: Profile }).profile, size, wall);
      const until = await typing.evaluate(() => performance.now());
      const paneRenders = await Promise.all(
        pages.map((page) => page.evaluate(() => Number((window as any).cmuxAcpmuxDebug.renders().pane ?? 0))),
      );
      const changes = await Promise.all(pages.map((page) => page.evaluate(() => (window as any).__scale.stop())));
      const stats = (await typing.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as Record<string, any>;
      const long = (
        (await typing.evaluate(
          () => (window as unknown as { __longTasks?: { at: number; ms: number }[] }).__longTasks ?? [],
        )) as { at: number; ms: number }[]
      ).filter((task) => task.at + task.ms >= since && task.at <= until);
      const windowChanges = (RATE * wall) / 1000;
      const emits = paneRenders.reduce((sum, value) => sum + value, 0);
      const row = {
        size,
        shape: SHAPE,
        pages: PAGES,
        newtabs: NEWTABS,
        rate: RATE,
        keys: stats.keys,
        to_frame_p50: round1(stats.to_frame?.p50_ms ?? 0),
        to_frame_p95: round1(stats.to_frame?.p95_ms ?? 0),
        to_paint_p50: round1(stats.to_paint?.p50_ms ?? 0),
        to_paint_p95: round1(stats.to_paint?.p95_ms ?? 0),
        busy_pct: round1((busy / wall) * 100),
        long_tasks: long.length,
        longest_task_ms: round1(Math.max(0, ...long.map((task) => task.ms))),
        pane_renders_per_change: round1(emits / Math.max(1, windowChanges * PAGES)),
        changes: changes.reduce((sum, value) => sum + value, 0),
      };
      results.push(row);
      console.log(
        `n=${size} ${SHAPE} pages=${PAGES} (${NEWTABS} new tab) rate=${RATE}/s: key to_frame p50 ${row.to_frame_p50} p95 ${row.to_frame_p95} ms, ` +
          `to_paint p50 ${row.to_paint_p50} p95 ${row.to_paint_p95} ms, main thread busy ${row.busy_pct} %, ` +
          `long tasks ${row.long_tasks} (longest ${row.longest_task_ms} ms), pane renders/change/page ${row.pane_renders_per_change}`,
      );
      perfRow({
        name: `session_scale_typing.to_frame.n${size}`,
        p50: row.to_frame_p50,
        p95: row.to_frame_p95,
        target: TARGET_MS.frameWork,
      });
      await context.close();
    } finally {
      await browser.close();
    }
  }
  console.log(`SESSION-SCALE-TYPING ${JSON.stringify(results)}`);
} finally {
  await vite.close();
}
