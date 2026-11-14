// l10n-allow-file: bench output labels, not shipped UI.
// What one mouse-wheel tick costs in a small chat and in a huge one (Leo, 2026-11-07: "I do one tick
// up, one tick down ... we are proportionally scaling with the amounts of load our app has ... we're
// not, like, scrolling through a million events' worth of things"). The target: a tick's frames cost
// the same at any history size, and each fits a 120 Hz frame (8.3 ms).
//
// The real pane (`?mock`: the direct client on the in-page mock daemon), one fresh page per size, a chat
// of TURNS heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`, loadFixture.ts). The reader
// scrolls a few viewports up into the history and lets older pages land, then sends notched wheel ticks
// (deltaMode 1, three lines: the notch path of wheelGlide.ts, as a mouse with a notched wheel takes):
//   single: one tick up, its glide to rest, one tick down, its glide to rest; ROUNDS times;
//   burst:  eight ticks up 50 ms apart, then eight down (a reader spinning the wheel).
// With mode=live the chat also streams a turn while the ticks run (a 32-character delta every 50 ms and
// a tool call every 20 deltas, the mock daemon's streamLoadTurn), as a busy chat such as a coordinator's
// gets messages while its reader scrolls; mode=still scrolls a chat with nothing arriving.
// Each animation frame from the first tick to the last glide's rest is timed from its start (the rAF
// timestamp) until the page has rendered it (a posted message runs after the rendering update): the
// frame's work, which a 120 Hz display needs under 8.3 ms whatever this runner's own refresh is. Also:
// the first frame that moved after each tick (the tick's response), frames that did not move while a
// glide was on (a stall), long tasks over 50 ms (Chromium), and the transcript's React and layout time
// per frame (acpmuxPerf).
//   bun bench/wheel-tick-scaling.bench.ts [sizes=50,500,3000] [rounds=6] [engine=chromium|webkit] [mode=still|live]
// CMUX_TICK_INPUT=precise sends what a trackpad or a smoothing tool (Mos) sends instead: real pixel wheel
// input (Playwright's mouse.wheel, so the browser scrolls natively), each tick 20 eased events 8 ms apart
// over 120 px, and two fast flicks of 3,000 px. wheelGlide.ts leaves such input to the browser, so what
// can jolt it is the page writing the scroll offset while the reader scrolls: those writes are counted
// (js_writes, js_write_max_px: an anchor or follow correction during a scroll), and frames that moved
// against the input (reversals). notch_events must be 0 (the glide took none of it).
// CMUX_TICK_PROFILE=1 (Chromium) also records a CPU profile over each size's ticks and prints the
// functions with the most self time (bench diagnostics; keep it off for timing comparisons).
// Prints one line per size and PERF_ROW rows: wheel_tick.<engine>.<mode>.turns_<n>.work_ms (p50/p95) and
// wheel_tick.<engine>.<mode>.scaling.work_p95_ratio (the largest size's p95 over the smallest's; 1 is flat).
/// <reference types="bun" />
import path from "node:path";
import { chromium, webkit } from "playwright";
import { SourceMapConsumer, type RawSourceMap } from "source-map-js";
import { createServer, type ViteDevServer } from "vite";
import { warmViteServer } from "../test/support/warmDevServer";
import { perfRow, TARGET_MS } from "./perfRow";

const SIZES = (process.argv[2] ?? "50,500,3000").split(",").map(Number);
const ROUNDS = Number(process.argv[3] ?? 6);
const ENGINE = process.argv[4] ?? "chromium";
const MODE = process.argv[5] ?? "still";
if (MODE !== "still" && MODE !== "live") throw new Error(`wheel-tick-scaling: unknown mode ${MODE}`);
if (!SIZES.every((size) => Number.isInteger(size) && size > 0) || !Number.isInteger(ROUNDS) || ROUNDS < 1)
  throw new Error("usage: wheel-tick-scaling.bench.ts [sizes=50,500,3000] [rounds>=1] [engine=chromium|webkit]");
if (ENGINE !== "chromium" && ENGINE !== "webkit") throw new Error(`wheel-tick-scaling: unknown engine ${ENGINE}`);
const BUDGET_120 = 1000 / 120;
const PROFILE = process.env.CMUX_TICK_PROFILE === "1" && ENGINE === "chromium";
const INPUT_NAME = process.env.CMUX_TICK_INPUT ?? "notch";
if (INPUT_NAME !== "notch" && INPUT_NAME !== "precise")
  throw new Error(`wheel-tick-scaling: unknown input ${INPUT_NAME}`);
const INPUT: "notch" | "precise" = INPUT_NAME;
const webviews = path.resolve(import.meta.dir, "..");

type Summary = { p50: number; p95: number; max: number };
type SizeResult = {
  turns: number;
  loaded_px: number;
  history_left: boolean;
  open_ms: number;
  frames: number;
  work: Summary;
  over_120: number;
  over_60: number;
  react: Summary;
  layout: Summary;
  response_frames: Summary;
  stalls: number;
  failed_ticks: number;
  long_tasks: number;
  long_task_max: number;
  ticks: number;
  heap_mb: number | null;
  dom_nodes: number;
  spans: string;
  notch_events: number;
  js_writes: number;
  js_write_max_px: number;
  write_stacks: string[];
  reversals: number;
  moved_frames: number;
};

/// Runs in the page: the ticks and the frame record. Returns the size's result less its open numbers.
async function tickRun({
  rounds,
  session,
  live,
  pagingMs,
  input,
  hold,
}: {
  rounds: number;
  session: string;
  live: boolean;
  pagingMs: number;
  input: "notch" | "precise";
  /// Waits after paging and settling until the bench sets `cmuxTickGo` (it starts its CPU profile then).
  hold: boolean;
}): Promise<Omit<SizeResult, "turns" | "open_ms"> | { error: string }> {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return { error: "no transcript" };
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const afterRender = () =>
    new Promise<number>((resolve) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        resolve(performance.now());
      };
      channel.port2.postMessage(0);
    });
  // The pane server's root is src/agent-session/acpmux (vite.config.acpmux-pane.mjs).
  const perfUrl = "/perf.ts";
  type PerfModule = typeof import("../src/agent-session/acpmux/perf");
  const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
  const intentUrl = "/conversation/userScroll.ts";
  type IntentModule = typeof import("../src/agent-session/acpmux/conversation/userScroll");
  const { userScrollIntent } = (await import(/* @vite-ignore */ intentUrl)) as IntentModule;

  // Into the history as a reader goes there: up to the top of what is loaded, again and again, so older
  // pages land, until the transcript stops growing for two seconds or the paging deadline passes. Then
  // the ticks run from the middle of the loaded rows, where a reader who scrolled back through a long
  // chat is. A row's aria-setsize is the row count once nothing older is left to load, else -1.
  const olderLeft = () =>
    scroller.querySelector<HTMLElement>(".acpmux-row[aria-setsize]")?.getAttribute("aria-setsize") === "-1";
  const requested = userScrollIntent(scroller).request();
  scroller.scrollTop = scroller.scrollHeight;
  for (let index = 0; index < 20; index += 1) await frame();
  const pagingEnds = performance.now() + pagingMs;
  let grewAt = performance.now();
  let height = scroller.scrollHeight;
  while (performance.now() - grewAt < 2000 && performance.now() < pagingEnds) {
    if (requested()) scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight * 4);
    await frame();
    if (scroller.scrollHeight > height + 1) {
      height = scroller.scrollHeight;
      grewAt = performance.now();
    }
    if (!olderLeft() && scroller.scrollTop <= 0) break;
  }
  if (requested()) scroller.scrollTop = Math.round((scroller.scrollHeight - scroller.clientHeight) / 2);
  for (let index = 0; index < 60; index += 1) await frame();
  const loadedPx = scroller.scrollHeight;
  const historyLeft = olderLeft();

  const longTasks: number[] = [];
  let observer: PerformanceObserver | undefined;
  if (PerformanceObserver.supportedEntryTypes?.includes("longtask")) {
    observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) longTasks.push(entry.duration);
    });
    observer.observe({ type: "longtask" });
  }
  acpmuxPerf.enable();
  acpmuxPerf.resetFrames();
  let streaming = true;
  if (live) {
    const mockUrl = "/mock.ts";
    type MockModule = typeof import("../src/agent-session/acpmux/mock");
    const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
    if (!MockAcpmuxSocket.live) return { error: "no mock daemon" };
    void MockAcpmuxSocket.live
      .streamLoadTurn(session, { seconds: 120, chunkChars: 32, chunkMs: 50, toolEvery: 20 })
      .finally(() => (streaming = false));
  }

  // Precise input: the scroller's offset writes while the reader scrolls (a wheel event in the last
  // 200 ms), and the wheel events the glide would have taken.
  const glideUrl = "/wheelGlide.ts";
  type GlideModule = typeof import("../src/agent-session/acpmux/wheelGlide");
  const { isWheelNotch } = (await import(/* @vite-ignore */ glideUrl)) as GlideModule;
  let lastWheel = Number.NEGATIVE_INFINITY;
  let notchEvents = 0;
  let jsWrites = 0;
  let jsWriteMax = 0;
  const onWheel = (event: WheelEvent) => {
    lastWheel = performance.now();
    if (isWheelNotch(event)) notchEvents += 1;
  };
  const offset = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
  // Who wrote it: the first callers of each distinct write that moved the view, as the engine names them.
  const writeStacks = new Map<string, number>();
  const wrote = (before: number) => {
    if (performance.now() - lastWheel > 200) return;
    jsWrites += 1;
    const moved = Math.abs(offset.get!.call(scroller) - before);
    jsWriteMax = Math.max(jsWriteMax, moved);
    if (moved < 1) return;
    const stack = (new Error().stack ?? "")
      .split("\n")
      .slice(2, 8)
      .map((line) =>
        line
          .trim()
          .replace(/https?:\/\/[^/]+/, "")
          .replace(/\?[^:]*/, ""),
      )
      .join(" < ");
    if (writeStacks.size < 8 || writeStacks.has(stack)) writeStacks.set(stack, (writeStacks.get(stack) ?? 0) + 1);
  };
  if (input === "precise") {
    scroller.addEventListener("wheel", onWheel, { passive: true });
    Object.defineProperty(scroller, "scrollTop", {
      configurable: true,
      get() {
        return offset.get!.call(this);
      },
      set(value: number) {
        const before = offset.get!.call(this);
        offset.set!.call(this, value);
        wrote(before);
      },
    });
    for (const name of ["scrollTo", "scrollBy"] as const) {
      const original = Element.prototype[name];
      Object.defineProperty(scroller, name, {
        configurable: true,
        value(this: Element, ...args: unknown[]) {
          const before = offset.get!.call(this);
          (original as (...args: unknown[]) => void).apply(this, args);
          wrote(before);
        },
      });
    }
  }
  const signals = window as unknown as {
    cmuxTickSettled?: boolean;
    cmuxTickGo?: boolean;
    cmuxTickReady?: boolean;
    cmuxTickInputDone?: boolean;
  };
  signals.cmuxTickSettled = true;
  while (hold && !signals.cmuxTickGo) await frame();
  const work: number[] = [];
  const responses: number[] = [];
  let reversals = 0;
  let movedFrames = 0;
  let stalls = 0;
  let failedTicks = 0;
  let ticks = 0;
  let lastTop = scroller.scrollTop;
  let frameStart = await frame();
  /// One frame: times its work, marks it into acpmuxPerf, and says whether the transcript moved.
  const step = async (): Promise<boolean> => {
    const done = await afterRender();
    work.push(done - frameStart);
    const next = await frame();
    acpmuxPerf.markFrame(next, false);
    frameStart = next;
    const top = offset.get!.call(scroller);
    const moved = Math.abs(top - lastTop) >= 0.5;
    if (moved) movedFrames += 1;
    const direction = (window as unknown as { cmuxTickDirection?: number }).cmuxTickDirection ?? 0;
    if (moved && direction && Math.sign(top - lastTop) !== direction) reversals += 1;
    lastTop = top;
    return moved;
  };
  const tick = (lines: number) => {
    ticks += 1;
    scroller.dispatchEvent(
      new WheelEvent("wheel", {
        deltaY: lines,
        deltaMode: 1,
        cancelable: true,
        bubbles: true,
        clientX: 10,
        clientY: 10,
      }),
    );
  };
  /// After a tick: frames until the first move (the response), then until the glide rests for 6 frames. A
  /// tick that never moves within `cap` frames counts as failed; still frames inside its glide as stalls.
  const ride = async (cap = 240) => {
    let frames = 0;
    let moved = false;
    let still = 0;
    const moves: boolean[] = [];
    while (frames < cap) {
      frames += 1;
      const now = await step();
      if (!moved) {
        if (now) {
          moved = true;
          responses.push(frames);
          moves.push(true);
        }
        continue;
      }
      moves.push(now);
      if (now) {
        still = 0;
      } else if ((still += 1) >= 6) {
        break;
      }
    }
    if (!moved) failedTicks += 1;
    glideStalls(moves);
  };
  const glideStalls = (moves: boolean[]) => {
    // A still frame between two moving frames, inside one glide.
    for (let index = 1; index < moves.length - 1; index += 1)
      if (!moves[index] && moves.slice(0, index).includes(true) && moves.slice(index + 1).includes(true)) stalls += 1;
  };

  if (input === "precise") {
    // The bench sends the input from outside the page; the frames are recorded until it is done.
    signals.cmuxTickReady = true;
    while (!signals.cmuxTickInputDone) await step();
    for (let index = 0; index < 30; index += 1) await step();
    scroller.removeEventListener("wheel", onWheel);
    delete (scroller as unknown as Record<string, unknown>).scrollTop;
    delete (scroller as unknown as Record<string, unknown>).scrollTo;
    delete (scroller as unknown as Record<string, unknown>).scrollBy;
  }
  for (let round = 0; round < (input === "precise" ? 0 : rounds); round += 1) {
    tick(-3);
    await ride();
    tick(3);
    await ride();
  }
  for (const direction of input === "precise" ? [] : [-3, 3]) {
    const moves: boolean[] = [];
    let sent = 0;
    let next = performance.now();
    let still = 0;
    while (sent < 8 || still < 6) {
      if (sent < 8 && performance.now() >= next) {
        tick(direction);
        sent += 1;
        next += 50;
      }
      const moved = await step();
      moves.push(moved);
      still = moved ? 0 : still + 1;
      if (moves.length > 600) break;
    }
    glideStalls(moves);
  }
  observer?.disconnect();
  if (live && !streaming) return { error: "the stream ended before the ticks did" };
  const perf = acpmuxPerf.stats() as {
    react: { p50_ms: number; p95_ms: number; max_ms: number };
    layout: { p50_ms: number; p95_ms: number; max_ms: number };
    spans: Record<string, { p50_ms: number; p95_ms: number; max_ms: number }>;
  };
  // The transcript's own spans per frame, heaviest p95 first.
  const spans = Object.entries(perf.spans ?? {})
    .sort((a, b) => b[1].p95_ms - a[1].p95_ms)
    .slice(0, 6)
    .map(([name, value]) => `${name}:${value.p95_ms}/${value.max_ms}`)
    .join(",");
  const summary = (values: number[]): Summary => {
    const sorted = [...values].sort((a, b) => a - b);
    const at = (share: number) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))] ?? 0;
    const round2 = (value: number) => Math.round(value * 100) / 100;
    return { p50: round2(at(0.5)), p95: round2(at(0.95)), max: round2(sorted.at(-1) ?? 0) };
  };
  const pick = (value: { p50_ms: number; p95_ms: number; max_ms: number }): Summary => ({
    p50: value.p50_ms,
    p95: value.p95_ms,
    max: value.max_ms,
  });
  const heap = (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory?.usedJSHeapSize;
  return {
    loaded_px: loadedPx,
    history_left: historyLeft,
    frames: work.length,
    work: summary(work),
    over_120: work.filter((ms) => ms > 1000 / 120).length,
    over_60: work.filter((ms) => ms > 1000 / 60).length,
    react: pick(perf.react),
    layout: pick(perf.layout),
    response_frames: summary(responses),
    stalls,
    failed_ticks: failedTicks,
    long_tasks: longTasks.length,
    long_task_max: Math.round(Math.max(0, ...longTasks)),
    ticks,
    heap_mb: heap === undefined ? null : Math.round(heap / 1048576),
    dom_nodes: document.getElementsByTagName("*").length,
    spans,
    notch_events: notchEvents,
    js_writes: jsWrites,
    js_write_max_px: Math.round(jsWriteMax),
    write_stacks: [...writeStacks].map(([stack, count]) => `${count}x ${stack}`),
    reversals,
    moved_frames: movedFrames,
  };
}

type ProfileNode = {
  id: number;
  callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number };
  children?: number[];
};
/// The 25 source places with the most self time in a CDP CPU profile, with each one's share. Frames are
/// mapped through the dev server's source maps back to the source line (the served module is transformed).
/// A native call among them (`getBoundingClientRect`, where a forced layout lands) also names the source
/// places that called it, since the layout it forces is the caller's cost.
async function printProfile(
  server: ViteDevServer,
  turns: number,
  profile: { nodes: ProfileNode[]; samples?: number[]; timeDeltas?: number[] },
) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const maps = new Map<string, SourceMapConsumer | null>();
  const mapOf = (url: string) => {
    if (maps.has(url)) return maps.get(url)!;
    let consumer: SourceMapConsumer | null = null;
    try {
      const pathname = new URL(url).pathname;
      const map = server.moduleGraph.urlToModuleMap.get(pathname)?.transformResult?.map as RawSourceMap | null;
      if (map?.mappings) consumer = new SourceMapConsumer(map);
    } catch {
      consumer = null;
    }
    maps.set(url, consumer);
    return consumer;
  };
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const place = (node: ProfileNode) => {
    const { functionName, url, lineNumber, columnNumber } = node.callFrame;
    const original = url ? mapOf(url)?.originalPositionFor({ line: lineNumber + 1, column: columnNumber }) : undefined;
    const file = (original?.source ?? url).split("/").slice(-2).join("/").split("?")[0] ?? "";
    const line = original?.line ?? lineNumber + 1;
    return `${functionName || "(anonymous)"} ${file}:${line}`;
  };
  const self = new Map<string, number>();
  const callers = new Map<string, Map<string, number>>();
  let total = 0;
  (profile.samples ?? []).forEach((id, index) => {
    const node = byId.get(id);
    const ms = (profile.timeDeltas?.[index] ?? 0) / 1000;
    if (!node) return;
    const { functionName, url } = node.callFrame;
    if (functionName === "(idle)" || functionName === "(program)") return;
    const key = place(node);
    self.set(key, (self.get(key) ?? 0) + ms);
    total += ms;
    if (url || functionName.startsWith("(")) return;
    let up = parent.get(node.id);
    while (up !== undefined && !byId.get(up)?.callFrame.url) up = parent.get(up);
    const caller = up === undefined ? "(none)" : place(byId.get(up)!);
    const of = callers.get(key) ?? new Map<string, number>();
    of.set(caller, (of.get(caller) ?? 0) + ms);
    callers.set(key, of);
  });
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 25);
  const share = (ms: number) =>
    `${(Math.round(ms * 10) / 10).toString().padStart(8)} ms ${((ms / total) * 100).toFixed(1).padStart(5)}%`;
  console.log(`wheel-tick-scaling profile turns=${turns} busy_ms=${Math.round(total)}`);
  for (const [key, ms] of top) {
    console.log(`  ${share(ms)}  ${key}`);
    const of = callers.get(key);
    if (!of || ms < total * 0.02) continue;
    for (const [caller, callerMs] of [...of].sort((a, b) => b[1] - a[1]).slice(0, 4))
      console.log(`  ${share(callerMs)}    <- ${caller}`);
  }
}

// React's production build, as the app ships it: its development build spends most of a frame on its own
// checks (jsxDEV), which says nothing about the app. CMUX_TICK_DEV=1 keeps the development build.
const DEV = process.env.CMUX_TICK_DEV === "1";
if (!DEV) process.env.NODE_ENV = "production";
const vite = await createServer({
  mode: DEV ? "development" : "production",
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
await warmViteServer(vite, "/?mock");
const browser = await (ENGINE === "webkit" ? webkit : chromium).launch({ headless: true });
const results: SizeResult[] = [];
try {
  const { port } = vite.httpServer!.address() as { port: number };
  for (const turns of SIZES) {
    const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(
      (turns) =>
        (
          window as unknown as { cmuxAcpmuxDebug: { loadSeed(turns: number): Promise<unknown> } }
        ).cmuxAcpmuxDebug.loadSeed(turns),
      turns,
    )) as { error?: string; session: string; rows: number; open_ms: number };
    if (seeded.error) throw new Error(`wheel-tick-scaling: seed ${turns}: ${seeded.error}`);
    await page.locator(".acpmux-scroll").hover();
    const cdp = PROFILE ? await page.context().newCDPSession(page) : undefined;
    const running = page.evaluate(tickRun, {
      rounds: ROUNDS,
      session: seeded.session,
      live: MODE === "live",
      pagingMs: 120_000,
      input: INPUT,
      hold: cdp !== undefined,
    });
    // The profile covers the measured input only, not the history paging and mounting before it. A run
    // that ends before it settles (no transcript, no mock daemon) skips the profile and reports its error.
    const settled = cdp
      ? page
          .waitForFunction(() => (window as unknown as { cmuxTickSettled?: boolean }).cmuxTickSettled, null, {
            timeout: 180_000,
          })
          .then(
            () => true,
            // The page closed or the wait timed out after the run ended: no profile.
            () => false,
          )
      : Promise.resolve(false);
    let ended = false;
    const end = running.then(
      () => (ended = true),
      () => (ended = true),
    );
    const profiling = cdp !== undefined && (await Promise.race([settled, end.then(() => false)]));
    if (cdp && profiling) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    // A held run goes on whether or not it is profiled: a settle that timed out can still come later.
    if (cdp && !ended)
      await page
        .evaluate(() => {
          (window as unknown as { cmuxTickGo?: boolean }).cmuxTickGo = true;
        })
        .catch(() => {});
    // A run that ended first (an error) gets no input: `await running` below reports it.
    const ready = async () =>
      !ended &&
      (await Promise.race([
        page
          .waitForFunction(() => (window as unknown as { cmuxTickReady?: boolean }).cmuxTickReady, null, {
            timeout: 180_000,
          })
          .then(() => true),
        end.then(() => false),
      ]));
    if (INPUT === "precise" && (await ready())) {
      // A tick or a flick as a smoothing tool sends it: `events` pixel deltas 8 ms apart, easing out, `total`
      // px in all. Deltas are fractional, never a legacy 120-unit notch. The pause between is input pacing.
      // Chromium's mouse.wheel sends legacy 120-unit ticks, which the glide takes as a notch; its synthetic
      // scroll gesture from a mouse sends precise wheel deltas, as a trackpad or Mos does.
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      const gesture = ENGINE === "chromium" ? (cdp ?? (await page.context().newCDPSession(page))) : undefined;
      const flick = async (total: number, events: number) => {
        await page.evaluate((direction) => {
          (window as unknown as { cmuxTickDirection?: number }).cmuxTickDirection = direction;
        }, Math.sign(total));
        if (gesture) {
          await gesture.send("Input.synthesizeScrollGesture", {
            x: Math.round(box.x + box.width / 2),
            y: Math.round(box.y + box.height / 2),
            yDistance: -total,
            speed: Math.round(Math.abs(total) / ((events * 8) / 1000)),
            gestureSourceType: "mouse",
          });
          await new Promise((resolve) => setTimeout(resolve, 400));
          return;
        }
        const weights = Array.from({ length: events }, (_, index) => (1 - index / events) ** 2);
        const sum = weights.reduce((a, b) => a + b, 0);
        for (const weight of weights) {
          await page.mouse.wheel(0, (total * weight) / sum);
          await new Promise((resolve) => setTimeout(resolve, 8));
        }
        await new Promise((resolve) => setTimeout(resolve, 400));
      };
      for (let round = 0; round < ROUNDS; round += 1) {
        await flick(-120, 20);
        await flick(120, 20);
      }
      await flick(-3000, 60);
      await flick(3000, 60);
      await page.evaluate(() => {
        (window as unknown as { cmuxTickInputDone?: boolean }).cmuxTickInputDone = true;
      });
    }
    const run = await running;
    if (cdp && profiling) await printProfile(vite, turns, (await cdp.send("Profiler.stop")).profile);
    await page.close();
    if ("error" in run) throw new Error(`wheel-tick-scaling: ${turns} turns: ${run.error}`);
    if ((INPUT === "precise" ? run.moved_frames === 0 : run.response_frames.p50 === 0) || run.frames < ROUNDS * 4)
      throw new Error(
        `wheel-tick-scaling: ${turns} turns: the ticks did not move the transcript ${JSON.stringify(run)}`,
      );
    const result = { turns, open_ms: seeded.open_ms, ...run };
    results.push(result);
    const pick = ({ p50, p95, max }: Summary) => `${p50}/${p95}/${max}`;
    console.log(
      `wheel-tick-scaling ${ENGINE} ${MODE}${INPUT === "precise" ? " precise" : ""}${DEV ? " dev" : ""} turns=${turns} loaded_px=${result.loaded_px} history_left=${result.history_left} frames=${result.frames} ticks=${result.ticks} ` +
        `work=${pick(result.work)} over_120=${result.over_120} over_60=${result.over_60} ` +
        `react=${pick(result.react)} layout=${pick(result.layout)} response_frames=${pick(result.response_frames)} ` +
        `stalls=${result.stalls} failed_ticks=${result.failed_ticks} long_tasks=${result.long_tasks} long_task_max=${result.long_task_max} ` +
        `heap_mb=${result.heap_mb} dom_nodes=${result.dom_nodes} open_ms=${result.open_ms} spans_p95/max=${result.spans}` +
        (INPUT === "precise"
          ? ` moved_frames=${result.moved_frames} reversals=${result.reversals} js_writes=${result.js_writes} js_write_max_px=${result.js_write_max_px} notch_events=${result.notch_events}` +
            result.write_stacks.map((stack) => `\n    write ${stack}`).join("")
          : ""),
    );
    perfRow({
      name: `wheel_tick.${ENGINE}.${MODE}${INPUT === "precise" ? ".precise" : ""}.turns_${turns}.work_ms`,
      p50: result.work.p50,
      p95: result.work.p95,
      target: BUDGET_120,
    });
  }
  const first = results[0]!;
  const last = results.at(-1)!;
  if (results.length > 1) {
    const ratio = Math.round((last.work.p95 / Math.max(0.01, first.work.p95)) * 100) / 100;
    console.log(
      `wheel-tick-scaling ${ENGINE} ${MODE} scaling: turns ${first.turns} -> ${last.turns}: work p95 x${ratio}`,
    );
    perfRow({
      name: `wheel_tick.${ENGINE}.${MODE}${INPUT === "precise" ? ".precise" : ""}.scaling.work_p95_ratio`,
      p95: ratio,
      unit: "x",
      target: 1.2,
    });
  }
  void TARGET_MS;
} finally {
  await browser.close();
  await vite.close();
}
