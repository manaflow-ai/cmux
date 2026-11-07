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
// CMUX_TICK_PROFILE=1 (Chromium) also records a CPU profile over each size's ticks and prints the
// functions with the most self time (bench diagnostics; keep it off for timing comparisons).
// Prints one line per size and PERF_ROW rows: wheel_tick.<engine>.<mode>.turns_<n>.work_ms (p50/p95) and
// wheel_tick.<engine>.<mode>.scaling.work_p95_ratio (the largest size's p95 over the smallest's; 1 is flat).
/// <reference types="bun" />
import path from "node:path";
import { chromium, webkit } from "playwright";
import { createServer } from "vite";
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
const webviews = path.resolve(import.meta.dir, "..");

type Summary = { p50: number; p95: number; max: number };
type SizeResult = {
  turns: number;
  rows: number;
  open_ms: number;
  frames: number;
  work: Summary;
  over_120: number;
  over_60: number;
  react: Summary;
  layout: Summary;
  response_frames: Summary;
  stalls: number;
  long_tasks: number;
  long_task_max: number;
  ticks: number;
  heap_mb: number | null;
  dom_nodes: number;
  spans: string;
};

/// Runs in the page: the ticks and the frame record. Returns the size's result less its open numbers.
async function tickRun({
  rounds,
  session,
  live,
}: {
  rounds: number;
  session: string;
  live: boolean;
}): Promise<Omit<SizeResult, "turns" | "rows" | "open_ms"> | { error: string }> {
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
  const perfUrl = "/src/agent-session/acpmux/perf.ts";
  type PerfModule = typeof import("../src/agent-session/acpmux/perf");
  const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
  const intentUrl = "/src/agent-session/acpmux/conversation/userScroll.ts";
  type IntentModule = typeof import("../src/agent-session/acpmux/conversation/userScroll");
  const { userScrollIntent } = (await import(/* @vite-ignore */ intentUrl)) as IntentModule;

  // Into the history as a reader goes there: a few viewports up, then still frames while older pages land.
  const requested = userScrollIntent(scroller).request();
  scroller.scrollTop = scroller.scrollHeight;
  for (let index = 0; index < 20; index += 1) await frame();
  for (let step = 0; step < 6; step += 1) {
    if (requested()) scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight);
    for (let index = 0; index < 20; index += 1) await frame();
  }
  for (let index = 0; index < 60; index += 1) await frame();

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
    const mockUrl = "/src/agent-session/acpmux/mock.ts";
    type MockModule = typeof import("../src/agent-session/acpmux/mock");
    const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
    if (!MockAcpmuxSocket.live) return { error: "no mock daemon" };
    void MockAcpmuxSocket.live
      .streamLoadTurn(session, { seconds: 120, chunkChars: 32, chunkMs: 50, toolEvery: 20 })
      .finally(() => (streaming = false));
  }

  const work: number[] = [];
  const responses: number[] = [];
  let stalls = 0;
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
    const moved = Math.abs(scroller.scrollTop - lastTop) >= 0.5;
    lastTop = scroller.scrollTop;
    return moved;
  };
  const tick = (lines: number) => {
    ticks += 1;
    scroller.dispatchEvent(
      new WheelEvent("wheel", { deltaY: lines, deltaMode: 1, cancelable: true, bubbles: true, clientX: 10, clientY: 10 }),
    );
  };
  /// After a tick: frames until the first move (the response), then until the glide rests for 6 frames.
  const ride = async (cap = 240) => {
    let frames = 0;
    let moved = false;
    let still = 0;
    while (frames < cap) {
      frames += 1;
      const now = await step();
      if (!moved) {
        if (now) {
          moved = true;
          responses.push(frames);
        }
        continue;
      }
      if (now) {
        still = 0;
      } else if ((still += 1) >= 6) {
        // The frames that sat still before it came to rest were a stall only if it moved again after.
        return;
      }
    }
  };
  const glideStalls = (moves: boolean[]) => {
    // A still frame between two moving frames, inside one glide.
    for (let index = 1; index < moves.length - 1; index += 1)
      if (!moves[index] && moves.slice(0, index).includes(true) && moves.slice(index + 1).includes(true)) stalls += 1;
  };

  for (let round = 0; round < rounds; round += 1) {
    tick(-3);
    await ride();
    tick(3);
    await ride();
  }
  for (const direction of [-3, 3]) {
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
    frames: work.length,
    work: summary(work),
    over_120: work.filter((ms) => ms > 1000 / 120).length,
    over_60: work.filter((ms) => ms > 1000 / 60).length,
    react: pick(perf.react),
    layout: pick(perf.layout),
    response_frames: summary(responses),
    stalls,
    long_tasks: longTasks.length,
    long_task_max: Math.round(Math.max(0, ...longTasks)),
    ticks,
    heap_mb: heap === undefined ? null : Math.round(heap / 1048576),
    dom_nodes: document.getElementsByTagName("*").length,
    spans,
  };
}

type ProfileNode = {
  id: number;
  callFrame: { functionName: string; url: string; lineNumber: number };
  children?: number[];
};
/// The 25 functions with the most self time in a CDP CPU profile, with each one's share.
function printProfile(turns: number, profile: { nodes: ProfileNode[]; samples: number[]; timeDeltas: number[] }) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map<string, number>();
  let total = 0;
  profile.samples.forEach((id, index) => {
    const node = byId.get(id);
    const ms = (profile.timeDeltas[index] ?? 0) / 1000;
    if (!node) return;
    const { functionName, url, lineNumber } = node.callFrame;
    if (functionName === "(idle)" || functionName === "(program)") return;
    const file = url.split("/").slice(-1)[0]?.split("?")[0] ?? "";
    const key = `${functionName || "(anonymous)"} ${file}:${lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + ms);
    total += ms;
  });
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 25);
  console.log(`wheel-tick-scaling profile turns=${turns} busy_ms=${Math.round(total)}`);
  for (const [key, ms] of top)
    console.log(`  ${(Math.round(ms * 10) / 10).toString().padStart(8)} ms ${((ms / total) * 100).toFixed(1).padStart(5)}%  ${key}`);
}

const vite = await createServer({
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
      (turns) => (window as unknown as { cmuxAcpmuxDebug: { loadSeed(turns: number): Promise<unknown> } }).cmuxAcpmuxDebug.loadSeed(turns),
      turns,
    )) as { error?: string; session: string; rows: number; open_ms: number };
    if (seeded.error) throw new Error(`wheel-tick-scaling: seed ${turns}: ${seeded.error}`);
    await page.locator(".acpmux-scroll").hover();
    const cdp = PROFILE ? await page.context().newCDPSession(page) : undefined;
    if (cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    const run = await page.evaluate(tickRun, { rounds: ROUNDS, session: seeded.session, live: MODE === "live" });
    if (cdp) printProfile(turns, (await cdp.send("Profiler.stop")).profile);
    await page.close();
    if ("error" in run) throw new Error(`wheel-tick-scaling: ${turns} turns: ${run.error}`);
    if (run.response_frames.p50 === 0 || run.frames < ROUNDS * 4)
      throw new Error(`wheel-tick-scaling: ${turns} turns: the ticks did not move the transcript ${JSON.stringify(run)}`);
    const result = { turns, rows: seeded.rows, open_ms: seeded.open_ms, ...run };
    results.push(result);
    const pick = ({ p50, p95, max }: Summary) => `${p50}/${p95}/${max}`;
    console.log(
      `wheel-tick-scaling ${ENGINE} ${MODE} turns=${turns} rows=${result.rows} frames=${result.frames} ticks=${result.ticks} ` +
        `work=${pick(result.work)} over_120=${result.over_120} over_60=${result.over_60} ` +
        `react=${pick(result.react)} layout=${pick(result.layout)} response_frames=${pick(result.response_frames)} ` +
        `stalls=${result.stalls} long_tasks=${result.long_tasks} long_task_max=${result.long_task_max} ` +
        `heap_mb=${result.heap_mb} dom_nodes=${result.dom_nodes} open_ms=${result.open_ms} spans_p95/max=${result.spans}`,
    );
    perfRow({
      name: `wheel_tick.${ENGINE}.${MODE}.turns_${turns}.work_ms`,
      p50: result.work.p50,
      p95: result.work.p95,
      target: BUDGET_120,
    });
  }
  const first = results[0]!;
  const last = results.at(-1)!;
  if (results.length > 1) {
    const ratio = Math.round((last.work.p95 / Math.max(0.01, first.work.p95)) * 100) / 100;
    console.log(`wheel-tick-scaling ${ENGINE} ${MODE} scaling: turns ${first.turns} -> ${last.turns}: work p95 x${ratio}`);
    perfRow({ name: `wheel_tick.${ENGINE}.${MODE}.scaling.work_p95_ratio`, p95: ratio, unit: "x", target: 1.2 });
  }
  void TARGET_MS;
} finally {
  await browser.close();
  await vite.close();
}
