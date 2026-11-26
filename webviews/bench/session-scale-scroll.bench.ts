// l10n-allow-file: benchmark output, not shipped UI.
// Scrolling a short chat while thousands of other chats change, with the pages nobody shows in the same
// renderer (Lawrence, 2026-11-18: dropped frames scrolling a short chat on a large real-world profile, many
// workspaces and a long history; a sparse profile showed none). Leo: "Why should non visible thing even
// affect the renderer thread anyways?"
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon, served as production
// React by Vite) in PAGES pages of one Chromium renderer (`--renderer-process-limit=1`, as the app runs its
// agent pages). Every page lists SIZE sessions (`cmuxAcpmuxMockListSize`), and its mock daemon changes a
// random listed session RATE times a second, each change carrying PAD bytes of row detail, as a busy
// daemon's `session_changed` does. The first page shows a short chat (TURNS light turns) and is scrolled
// by real wheel input; the rest are what the app keeps hidden: one long chat (LONG turns) and NEWTABS New
// Tab pages (a tab's New Tab and the prewarmed spare).
//
// `--hidden` says what the hidden pages are told: `hidden` (their `visibilityState` reads hidden, as a
// page in a background workspace does), `visible` (it reads visible, as the native side reports the spare
// and an orphaned New Tab page), or `both` (the default). Rows, per size and mode:
//   frame_p50 / frame_p95 / frame_max  the scrolled page's animation-frame intervals (tickWatch.ts), ms
//   dropped                            frames missed against 60 Hz over the scroll (perf.ts droppedFrames)
//   busy_pct                           the renderer main thread's task time over the scroll (CDP TaskDuration), %
//   long_tasks                         tasks of 50 ms or more in the scrolled page, and the longest
//   hidden_renders                     committed React renders in the hidden pages over the scroll, all
//                                      components (`cmuxAcpmuxDebug.renders`); a hidden page should draw none
//   bun bench/session-scale-scroll.bench.ts [--sizes 100,10000] [--pages 4] [--newtabs 2] [--rate 4]
//     [--pad 17000] [--cpu 1] [--turns 30] [--long 2000] [--seconds 6] [--hidden both|hidden|visible] [--profile]
//     [--hidden-rate R]  the rate the hidden pages hear (default --rate)
//     [--hidden-chats N --stream R [--stream-turns T] [--shed] [--wake]]  N more hidden chat pages (after the PAGES)
//       whose chat streams R records a second (agent text chunks of CHUNK chars, a tool call every 10th); `--shed` is
//       the host since its hidden shedding (AcpmuxPaneSocket+Hidden.swift): a hidden page gets the `host_hidden` start
//       marker in place of the first stream record left out and no more of them, and `--wake` shows the pages after
//       the scroll (the end marker with the count left out) and checks each read what it missed.
//   with --hidden-chats, more rows:
//     hidden_events_applied_per_s       the chat records the hidden chats' direct clients reduced (perf.ts
//                                       `records.applied`, counted in direct.ts `apply`), a second, all pages
//     hidden_frames_per_s               the stream frames the mock delivered to them, a second, all pages
//     busy_ms_per_s                     the renderer main thread's task time (CDP TaskDuration), ms a second
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession, Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";
import { requireProductionReact, installReactWatch } from "./support/benchPage";
import { perfRow, TARGET_MS } from "./perfRow";
import { printProfile, type CpuProfile } from "./support/profile";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "100,10000").split(",").map(Number);
const PAGES = Number(flag("--pages") ?? 4);
const NEWTABS = Number(flag("--newtabs") ?? 2);
const RATE = Number(flag("--rate") ?? 4);
/// The rate the hidden pages hear (default RATE). The app's host leaves other chats' row changes out for a page
/// nobody sees and tells it once when it shows (AcpmuxPaneSocket.setAsleep), so `--hidden-rate 0` is the app's
/// arm and the default the arm before it.
const HIDDEN_RATE = Number(flag("--hidden-rate") ?? RATE);
const PAD = Number(flag("--pad") ?? 17_000);
/// The share of changes that list a new chat (a sub-agent or a peer's chat started; `session_changed` `created`), as a
/// fleet's daemon tells: the list's length moves, which a row's in-place change never does.
const CHURN = Number(flag("--churn") ?? 0);
/// `fleet`: listed rows shaped like a fleet daemon's (mockFixture.ts `fleetListedSession`), else the plain ones.
const SHAPE = flag("--shape") ?? "plain";
/// No wheel input: the frames and the profile are what the pages cost with nobody scrolling, so what is left is the
/// work of what nobody looks at.
const IDLE = argv.includes("--idle");
/// The scrolled chat: a short one, a few screens tall.
const TURNS = Number(flag("--turns") ?? 30);
/// The hidden chat's turns (two rows each): a long coordinator chat.
const LONG = Number(flag("--long") ?? 2000);
const SECONDS = Number(flag("--seconds") ?? 6);
const SETTLE_MS = Number(flag("--settle") ?? 3000);
/// The renderer's CPU slowed this many times (CDP `Emulation.setCPUThrottlingRate`): a fleet core has more
/// headroom than a busy laptop's, so 1 reads a laptop's margin as larger than it is.
const CPU = Number(flag("--cpu") ?? 1);
const HIDDEN_MODE = flag("--hidden") ?? "both";
const MODES = (HIDDEN_MODE === "both" ? ["hidden", "visible"] : [HIDDEN_MODE]) as ("hidden" | "visible")[];
const PROFILE = argv.includes("--profile");
/// Streaming hidden chats after the PAGES, and the records a second each one's chat streams.
const HIDDEN_CHATS = Number(flag("--hidden-chats") ?? 0);
const STREAM = Number(flag("--stream") ?? 20);
const STREAM_TURNS = Number(flag("--stream-turns") ?? 200);
/// An agent text chunk's characters, as a streaming model's deltas batch.
const CHUNK = Number(flag("--chunk") ?? 300);
const SHED = argv.includes("--shed");
const WAKE = argv.includes("--wake");
/// The display the dropped frames are counted against.
const NOMINAL_MS = 1000 / 60;
/// One wheel notch every frame, as a trackpad's stream sends them; its direction turns every TURN_EVERY.
const WHEEL_MS = 16;
const WHEEL_PX = 60;
const TURN_EVERY = 25;
if (
  SIZES.some((size) => !Number.isInteger(size) || size < 0) ||
  !(PAGES >= 1) ||
  !(RATE >= 0) ||
  !(HIDDEN_RATE >= 0) ||
  !(SECONDS > 0) ||
  !(HIDDEN_CHATS >= 0) ||
  !(STREAM >= 0) ||
  MODES.some((mode) => mode !== "hidden" && mode !== "visible")
) {
  console.error("usage: bun bench/session-scale-scroll.bench.ts [--sizes 100,10000] [--hidden both|hidden|visible]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");

/// Init script: the page's `visibilityState` reads `__benchShown` (headless Chromium reports every page
/// visible), and `__benchShow(shown)` flips it and tells the page, as the app does when it shows or hides one.
function visibility() {
  const w = window as unknown as { __benchShown: boolean; __benchShow?: (shown: boolean) => void };
  if (w.__benchShow) return;
  w.__benchShown = true;
  Object.defineProperty(Document.prototype, "visibilityState", {
    configurable: true,
    get: () => (w.__benchShown ? "visible" : "hidden"),
  });
  Object.defineProperty(Document.prototype, "hidden", { configurable: true, get: () => !w.__benchShown });
  w.__benchShow = (shown: boolean) => {
    if (w.__benchShown === shown) return;
    w.__benchShown = shown;
    document.dispatchEvent(new Event("visibilitychange"));
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

/// In the page: every `1000 / rate` ms one listed session changes (its status flips, and it carries `pad`
/// characters of detail), the way the daemon tells a watcher: one `session_changed` with its summary.
async function installDriver({ size, rate, pad, churn }: { size: number; rate: number; pad: number; churn: number }) {
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
        if (churn > 0 && Math.random() < churn) {
          const raw = daemon as unknown as { sessions: Record<string, unknown>[]; deliver(message: unknown): void };
          const index = raw.sessions.length;
          const created = {
            sessionId: `churn-${index}-${round}`,
            name: `peer-${index % 30}/spawned-${round}`,
            peer: `peer-${index % 30}`,
            harness: "claude",
            cwd: `/home/agent/work/spawned-${round}`,
            status: "running",
            createdAt: Date.now(),
            updatedAt: Date.now(),
            title: `spawned ${round}`,
          };
          raw.sessions.push(created);
          raw.deliver({
            jsonrpc: "2.0",
            method: "_acpmux/session_changed",
            params: { kind: "created", session: created },
          });
          return;
        }
        daemon.changeSession(`listed-${Math.floor(Math.random() * size)}`, (current: Record<string, any>) => ({
          status: current.status === "running" ? "idle" : "running",
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

/// In a hidden chat page: its chat's agent streams `rate` records a second into the mock daemon (an open turn's text
/// chunks of `chunk` characters, every 10th a tool call that completes on the next). `shed`: the mock stands for the
/// host since its hidden shedding (AcpmuxPaneSocket+Hidden.swift `sheddableWhileHidden`): while `__stream.hide()` holds,
/// the chat's stream records (`_acpmux/event`, `session/update`) are left out but for the turn boundaries the page
/// waits on (AcpmuxPaneSocket+PageWaits.swift `waitedEventKinds`), the first one left out replaced by the
/// `host_hidden` start marker; `__stream.show()` sends the end marker with the count left out.
async function installStream({
  session,
  rate,
  chunk,
  shed,
}: {
  session: string;
  rate: number;
  chunk: number;
  shed: boolean;
}) {
  type MockModule = typeof import("../src/agent-session/acpmux/mock");
  const mockUrl = "/mock.ts";
  const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
  const daemon = MockAcpmuxSocket.live as any;
  if (!daemon) throw new Error("no mock daemon");
  const perfUrl = "/perf.ts";
  const { acpmuxPerf } = (await import(
    /* @vite-ignore */ perfUrl
  )) as typeof import("../src/agent-session/acpmux/perf");
  (window as any).__records = acpmuxPerf.records;
  const waited = new Set(["turn_end", "turn_result", "queued", "dequeued", "queue_removed", "prompt_refused"]);
  const deliver = daemon.deliver.bind(daemon) as (message: unknown) => void;
  const state = { hidden: false, startSent: false, dropped: 0, frames: 0, sent: 0, newest: 0 };
  daemon.deliver = (message: any) => {
    const stream = message?.method === "_acpmux/event" || message?.method === "session/update";
    if (stream) {
      const kind = message.method === "_acpmux/event" ? message.params?.kind : message.params?.update?.sessionUpdate;
      if (shed && state.hidden && !waited.has(kind)) {
        state.dropped += 1;
        if (state.startSent) return;
        state.startSent = true;
        return deliver({
          jsonrpc: "2.0",
          method: "_acpmux/lagged",
          params: { dropped: 0, reason: "host_hidden", phase: "start" },
        });
      }
      state.frames += 1;
    }
    deliver(message);
  };
  const words = "the hidden chat keeps streaming its answer while nobody looks at the pane ".repeat(
    Math.ceil(chunk / 70) + 1,
  );
  let timer: ReturnType<typeof setInterval> | undefined;
  let tick = 0;
  let open: string | undefined;
  daemon.emit(session, { mux: "user_message", msg: { text: "Stream a long answer" } });
  daemon.emit(session, { mux: "turn_started" });
  const record = (update: Record<string, unknown>) => {
    daemon.emit(session, { update });
    state.sent += 1;
    state.newest = daemon.lastSeqOf(session);
  };
  (window as any).__stream = {
    start() {
      if (rate <= 0 || timer) return;
      timer = setInterval(() => {
        tick += 1;
        if (open) {
          record({
            sessionUpdate: "tool_call_update",
            toolCallId: open,
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: words.slice(0, chunk) } }],
          });
          open = undefined;
        } else if (tick % 10 === 0) {
          open = `stream-tool-${tick}`;
          record({
            sessionUpdate: "tool_call",
            toolCallId: open,
            kind: "execute",
            title: `Run check ${tick}`,
            status: "in_progress",
            rawInput: { command: `bun test ${tick}` },
          });
        } else
          record({
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: ` [chunk ${tick}] ${words.slice(0, chunk - 14)}` },
          });
      }, 1000 / rate);
    },
    /// Stops the stream; its last record carries `mark`, which the transcript draws once the page has it.
    stop(mark: string) {
      if (timer) clearInterval(timer);
      timer = undefined;
      record({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: ` ${mark}.` } });
      return { ...state };
    },
    hide() {
      state.hidden = true;
    },
    show() {
      const dropped = state.dropped;
      state.hidden = false;
      state.startSent = false;
      state.dropped = 0;
      if (shed && dropped > 0)
        deliver({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped, reason: "host_hidden" } });
      return dropped;
    },
    state: () => ({ ...state }),
  };
}

/// The hidden chats' records taken so far (perf.ts `records`).
const takenRecords = (page: Page) =>
  page.evaluate(async () => {
    const perfUrl = "/perf.ts";
    const { acpmuxPerf } = (await import(
      /* @vite-ignore */ perfUrl
    )) as typeof import("../src/agent-session/acpmux/perf");
    return { ...acpmuxPerf.records };
  });

async function openPage(
  page: Page,
  port: number,
  size: number,
  kind: "chat" | "long" | "newtab" | "stream",
  rate: number,
) {
  await page.addInitScript(
    ({ count, newTab, shape }) => {
      const mock = globalThis as {
        cmuxAcpmuxMockListSize?: number;
        cmuxAcpmuxMockListShape?: string;
        __cmuxNewTabContext?: unknown;
      };
      mock.cmuxAcpmuxMockListSize = count;
      mock.cmuxAcpmuxMockListShape = shape;
      // A New Tab page as the app opens one: the host injects its context before the first render.
      if (newTab) mock.__cmuxNewTabContext = {};
    },
    { count: size, newTab: kind === "newtab", shape: SHAPE },
  );
  await page.addInitScript(visibility);
  await page.addInitScript(probe);
  await installReactWatch(page);
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 120_000 });
  await requireProductionReact(page, { dev: false });
  if (kind === "newtab") {
    await page.locator(".nt-screen").first().waitFor({ state: "attached", timeout: 30_000 });
  } else {
    const seeded = (await page.evaluate(
      (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
      kind === "chat" ? TURNS : kind === "stream" ? STREAM_TURNS : LONG,
    )) as Record<string, any>;
    if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
    await page.locator(".acpmux-scroll").first().waitFor({ timeout: 60_000 });
    if (kind === "stream")
      await page.evaluate(installStream, { session: String(seeded.session), rate: STREAM, chunk: CHUNK, shed: SHED });
  }
  await page.evaluate(installDriver, { size, rate, pad: PAD, churn: CHURN });
}

const taskMs = async (cdp: CDPSession) => {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((metric) => metric.name === "TaskDuration")!.value * 1000;
};
const round1 = (value: number) => Math.round(value * 10) / 10;
const renderCount = (counts: Record<string, number>) => Object.values(counts).reduce((sum, value) => sum + value, 0);

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
  for (const size of SIZES)
    for (const mode of MODES) {
      // One renderer for every page, as the app's agent pages share one.
      // Background pages keep their timers' pace: the stand-in daemon runs in each page, and the real one is not
      // a page's timer, so Chromium's background throttling would slow what a hidden page is told, not what it does.
      const browser = await chromium.launch({
        headless: true,
        args: [
          "--renderer-process-limit=1",
          "--disable-background-timer-throttling",
          "--disable-renderer-backgrounding",
          "--disable-backgrounding-occluded-windows",
        ],
      });
      try {
        const context = await browser.newContext({ viewport: { width: 1100, height: 820 } });
        const pages: Page[] = [];
        for (let index = 0; index < PAGES; index += 1) {
          const page = await context.newPage();
          const kind = index === 0 ? "chat" : index > PAGES - 1 - NEWTABS ? "newtab" : "long";
          await openPage(page, port, size, kind, index === 0 ? RATE : HIDDEN_RATE);
          pages.push(page);
        }
        const streaming: Page[] = [];
        for (let index = 0; index < HIDDEN_CHATS; index += 1) {
          const page = await context.newPage();
          await openPage(page, port, size, "stream", HIDDEN_RATE);
          pages.push(page);
          streaming.push(page);
        }
        const hidden = pages.slice(1);
        if (mode === "hidden") for (const page of hidden) await page.evaluate(() => (window as any).__benchShow(false));
        // The host hides them as their pane goes from view (the start marker in place of the next record).
        for (const page of streaming) await page.evaluate(() => (window as any).__stream.hide());
        const scrolled = pages[0]!;
        await scrolled.bringToFront();
        const cdp = await context.newCDPSession(scrolled);
        await cdp.send("Performance.enable");
        if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
        const box = (await scrolled.locator(".acpmux-scroll").first().boundingBox())!;
        await scrolled.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        for (const page of pages) await page.evaluate(() => (window as any).__scale.start());
        for (const page of streaming) await page.evaluate(() => (window as any).__stream.start());
        // fixed-wait: the change stream reaches its steady state (every page's list and caches warm) before the scroll.
        await scrolled.waitForTimeout(SETTLE_MS);
        // The first call turns render counting on; the second, after the scroll, reads it.
        await Promise.all(pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())));
        const since = await scrolled.evaluate(() => performance.now());
        const takenBefore = await Promise.all(streaming.map(takenRecords));
        const framesBefore = await Promise.all(
          streaming.map((page) => page.evaluate(() => (window as any).__stream.state().frames as number)),
        );
        const busyBefore = await taskMs(cdp);
        if (PROFILE) {
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
          await cdp.send("Profiler.start");
        }
        const started = await scrolled.evaluate(() => (window as any).cmuxAcpmuxDebug.tickWatch());
        if ((started as Record<string, unknown>).error) throw new Error(`tickWatch: ${JSON.stringify(started)}`);
        const wallBefore = performance.now();
        // The short chat opens at its bottom: the first notches go up.
        let notch = 0;
        while (performance.now() - wallBefore < SECONDS * 1000) {
          const up = Math.floor(notch / TURN_EVERY) % 2 === 0;
          if (!IDLE) await scrolled.mouse.wheel(0, up ? -WHEEL_PX : WHEEL_PX);
          notch += 1;
          await scrolled.waitForTimeout(WHEEL_MS);
        }
        const watch = (await scrolled.evaluate(
          (nominal) => (window as any).cmuxAcpmuxDebug.tickWatch({ stop: true, nominal_ms: nominal }),
          NOMINAL_MS,
        )) as Record<string, any>;
        const wall = performance.now() - wallBefore;
        const busy = (await taskMs(cdp)) - busyBefore;
        const takenAfter = await Promise.all(streaming.map(takenRecords));
        const framesAfter = await Promise.all(
          streaming.map((page) => page.evaluate(() => (window as any).__stream.state().frames as number)),
        );
        if (PROFILE)
          printProfile(
            ((await cdp.send("Profiler.stop")) as { profile: CpuProfile }).profile,
            `n=${size} ${mode}`,
            wall,
          );
        const until = await scrolled.evaluate(() => performance.now());
        const renders = (await Promise.all(
          pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())),
        )) as Record<string, number>[];
        const changes = await Promise.all(pages.map((page) => page.evaluate(() => (window as any).__scale.stop())));
        const marks = streaming.map((_, index) => `stream-end-mark-${index}-${Date.now()}`);
        const streamed = (await Promise.all(
          streaming.map((page, index) => page.evaluate((mark) => (window as any).__stream.stop(mark), marks[index]!)),
        )) as { sent: number; newest: number; frames: number }[];
        const appliedDelta = takenAfter.reduce(
          (sum, taken, index) => sum + taken.applied - takenBefore[index]!.applied,
          0,
        );
        const framesDelta = framesAfter.reduce((sum, frames, index) => sum + frames - framesBefore[index]!, 0);
        // --wake: each hidden chat shows and must reach its stream's last record (its seq taken, its mark drawn).
        let wake: { caught_up: number; of: number; ms: number; dropped: number[]; detail: unknown[] } | undefined;
        if (WAKE && streaming.length) {
          // fixed-wait: the stop's last record reaches (or is left out of) every page before it shows.
          await scrolled.waitForTimeout(200);
          const woke = performance.now();
          const dropped: number[] = [];
          for (const page of streaming) {
            await page.evaluate(() => (window as any).__benchShow(true));
            dropped.push(await page.evaluate(() => (window as any).__stream.show() as number));
          }
          const detail = await Promise.all(
            streaming.map(async (page, index) => {
              const newest = streamed[index]!.newest;
              const caught = await page
                .waitForFunction(
                  ({ newest, mark }) =>
                    (window as any).__records.newest >= newest &&
                    (document.querySelector(".acpmux-scroll")?.textContent?.includes(mark) ?? false),
                  { newest, mark: marks[index]! },
                  { timeout: 15_000, polling: 100 },
                )
                .then(() => true)
                .catch(() => false);
              const taken = await takenRecords(page);
              const drawn = await page.evaluate(
                (mark) => document.querySelector(".acpmux-scroll")?.textContent?.includes(mark) ?? false,
                marks[index]!,
              );
              return { caught, newest_seq: newest, taken_newest: taken.newest, read: taken.read, drawn };
            }),
          );
          wake = {
            caught_up: detail.filter((entry) => entry.caught).length,
            of: streaming.length,
            ms: Math.round(performance.now() - woke),
            dropped,
            detail,
          };
        }
        const long = (
          (await scrolled.evaluate(
            () => (window as unknown as { __longTasks?: { at: number; ms: number }[] }).__longTasks ?? [],
          )) as { at: number; ms: number }[]
        ).filter((task) => task.at + task.ms >= since && task.at <= until);
        const frames = watch.frames ?? {};
        const row = {
          size,
          hidden: mode,
          pages: PAGES,
          newtabs: NEWTABS,
          rate: RATE,
          hidden_rate: HIDDEN_RATE,
          cpu: CPU,
          turns: TURNS,
          frames: frames.frames,
          moved_frames: watch.moved_frames,
          wheel_events: watch.wheel_events,
          frame_p50: frames.p50_ms,
          frame_p95: frames.p95_ms,
          frame_max: frames.max_ms,
          dropped: frames.dropped_frames,
          busy_pct: round1((busy / wall) * 100),
          long_tasks: long.length,
          longest_task_ms: round1(Math.max(0, ...long.map((task) => task.ms))),
          shown_renders: renderCount(renders[0] ?? {}),
          hidden_renders: renders.slice(1).map(renderCount),
          hidden_pane_renders: renders.slice(1).map((counts) => counts.pane ?? 0),
          changes: changes.reduce((sum, value) => sum + value, 0),
          hidden_chats: HIDDEN_CHATS,
          churn: CHURN,
          shape: SHAPE,
          idle: IDLE,
          stream: STREAM,
          shed: SHED,
          busy_ms_per_s: round1((busy * 1000) / wall),
          hidden_events_applied_per_s: round1((appliedDelta * 1000) / wall),
          hidden_frames_per_s: round1((framesDelta * 1000) / wall),
          streamed_records: streamed.reduce((sum, value) => sum + value.sent, 0),
          wake,
        };
        results.push(row);
        console.log(
          `n=${size} hidden pages report ${mode}, pages=${PAGES} (${NEWTABS} new tab) rate=${RATE}/s hidden-rate=${HIDDEN_RATE}/s cpu=${CPU}x:` +
            `frames ${row.frames} p50 ${row.frame_p50} p95 ${row.frame_p95} max ${row.frame_max} ms, dropped ${row.dropped}, ` +
            `main thread busy ${row.busy_pct} %, long tasks ${row.long_tasks} (longest ${row.longest_task_ms} ms), ` +
            `hidden pages' renders ${JSON.stringify(row.hidden_renders)} (pane ${JSON.stringify(row.hidden_pane_renders)})` +
            (HIDDEN_CHATS
              ? `, ${HIDDEN_CHATS} hidden chats streaming ${STREAM}/s shed=${SHED}: applied ${row.hidden_events_applied_per_s}/s, ` +
                `frames ${row.hidden_frames_per_s}/s, busy ${row.busy_ms_per_s} ms/s` +
                (wake ? `, wake caught up ${wake.caught_up}/${wake.of} in ${wake.ms} ms` : "")
              : ""),
        );
        perfRow({
          name: `session_scale_scroll.frame.n${size}.${mode}`,
          p50: Number(row.frame_p50 ?? 0),
          p95: Number(row.frame_p95 ?? 0),
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
