// l10n-allow-file: bench output labels, not shipped UI.
// Per-frame cost of scrolling a long agent chat in real WebKit: the transcript harness
// (test/browser/transcript-fling.html) seeds ROWS synthetic rows, then a reader scrolls it two
// ways: the debug fling (debug.ts startFling, the frame pacing bench's fling, one scrollTop step
// per animation frame) and trackpad wheel input (page.mouse.wheel, 40 px a step, a step a frame),
// the slow reading scroll where a hitch shows. Prints, for each, frame intervals (p50/p95/max,
// dropped frames) and the transcript's own per-frame work (acpmuxPerf: React, layout, spans,
// vt.renders = renders of VirtualTranscript per frame).
//   bun bench/transcript-scroll-frame.bench.ts [rows=3000] [rounds=3] [hz=120]
// Set CMUX_SCROLL_COVERAGE=1 for a diagnostic pass with painted DOM coverage. Keep it off
// for timing comparisons: reading row rects can itself force layout. Headless cadence never
// establishes native 120 Hz presentation; this bench diagnoses the page's work and coverage.
// Each line: interval, react, layout and other are p50/p95/max ms per frame.
/// <reference types="bun" />
import path from "node:path";
import { webkit } from "playwright";
import { createServer } from "vite";
import { warmViteServer } from "../test/support/warmDevServer";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { frameStats } from "../src/agent-session/acpmux/perf";
import { perfRow, TARGET_MS } from "./perfRow";
import { startScrollCoverage, type ScrollCoverage } from "./scrollCoverage";

const ROWS = Number(process.argv[2] ?? 3000);
const ROUNDS = Number(process.argv[3] ?? 3);
const HZ = Number(process.argv[4] ?? 120);
const COVERAGE = process.env.CMUX_SCROLL_COVERAGE === "1";
if (!Number.isInteger(ROWS) || ROWS < 3 || !Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isFinite(HZ) || HZ <= 0)
  throw new Error("usage: transcript-scroll-frame.bench.ts [rows>=3] [rounds>=1] [hz>0]");
const webviews = path.resolve(import.meta.dir, "..");

const vite = await createServer({
  root: webviews,
  configFile: path.join(webviews, "vite.config.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const pagePath = "/test/browser/transcript-fling.html";
await warmViteServer(vite, pagePath);
const browser = await webkit.launch({ headless: true });
try {
  const { port } = vite.httpServer!.address() as { port: number };
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await installPaintedFrames(page);
  await page.goto(`http://127.0.0.1:${port}${pagePath}`);
  await page.waitForFunction(() => "__debug" in window);
  const seeded = await page.evaluate(`window.__debug.seedRows(${ROWS})`);
  console.log(`transcript-scroll-frame fixture=${JSON.stringify(seeded)} nominal_hz=${HZ} coverage=${COVERAGE}`);
  await page.locator(".acpmux-scroll").hover();

  /// What debug.ts's flingStats and perf.ts's stats report, as far as this bench reads them.
  type Summary = { p50_ms: number; p95_ms: number; max_ms: number };
  type Frames = Summary & {
    frames: number;
    dropped_frames: number;
    duration_ms: number;
    dropped_per_second: number;
  };
  type Perf = {
    blank_frames: number;
    react: Summary;
    layout: Summary;
    other: Summary;
    spans: Record<string, Summary>;
  };
  type Debug = {
    startFling(
      seconds: number,
      options: { wait: boolean; nominal_ms?: number },
    ): Promise<Summary & { frames: number; dropped_frames: number; running: boolean; distance_px: number }>;
    perfStats(options?: { raw: boolean }): Perf & { samples: { interval_ms: number }[] };
  };
  const beginCoverage = async (seconds: number) => {
    if (!COVERAGE) return;
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      for (let frame = 0; frame < 30; frame += 1) await window.cmuxPaintFrame();
    });
    await page.evaluate(startScrollCoverage, { timeoutMs: seconds * 1000 + 30_000 });
  };
  const endCoverage = async (): Promise<ScrollCoverage | null> => {
    if (!COVERAGE) return null;
    await page.evaluate(() => window.cmuxPaintFrame());
    const coverage = await page.evaluate(() => window.__stopScrollCoverage!());
    if (coverage.timed_out || coverage.frames < 2 || coverage.distance_px <= 0)
      throw new Error(`scroll bench: incomplete coverage ${JSON.stringify(coverage)}`);
    return coverage;
  };
  const fling = async (seconds = 3) => {
    await beginCoverage(seconds);
    const measured = await page.evaluate(
      async ({ seconds, hz }) => {
        const debug = (window as unknown as { __debug: Debug }).__debug;
        const fling = await debug.startFling(seconds, { wait: true, nominal_ms: 1000 / hz });
        // The ring holds actual intervals; wall time would include warm-up and transport.
        const { samples, ...perf } = debug.perfStats({ raw: true });
        if (!samples?.length) throw new Error("scroll bench: fling produced no frame samples");
        if (fling.running || fling.distance_px <= 0 || samples.length !== fling.frames - 1)
          throw new Error("scroll bench: incomplete fling or truncated frame ring");
        const duration_ms = samples.reduce((sum, sample) => sum + sample.interval_ms, 0);
        if (duration_ms < seconds * 1000 - 10)
          throw new Error("scroll bench: fling ended before its requested duration");
        return {
          fling: {
            ...fling,
            duration_ms,
            dropped_per_second: duration_ms > 0 ? (fling.dropped_frames * 1000) / duration_ms : 0,
          },
          perf,
        };
      },
      { seconds, hz: HZ },
    );
    return { ...measured, coverage: await endCoverage() };
  };
  // Wheel: from the latest message upward, one 40 px step a frame for `steps` frames. The frames
  // are marked into acpmuxPerf (the same module instance the page runs, through Vite) as the
  // fling marks its own.
  const wheel = async (steps: number) => {
    await beginCoverage(steps / HZ);
    const initialTop = await page.evaluate(async () => {
      // The page's URL for the module, which tsc cannot resolve from here: a variable, not a literal.
      const perfUrl = "/src/agent-session/acpmux/perf.ts";
      type PerfModule = typeof import("../src/agent-session/acpmux/perf");
      const { acpmuxPerf, isBlank } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      for (let frame = 0; frame < 30; frame += 1) await new Promise(requestAnimationFrame);
      acpmuxPerf.enable();
      acpmuxPerf.resetFrames();
      const w = window as unknown as { __wheelFrames: number[]; __wheelRun: boolean };
      w.__wheelFrames = [];
      w.__wheelRun = true;
      const tick = (now: number) => {
        if (!w.__wheelRun) return;
        w.__wheelFrames.push(now);
        acpmuxPerf.markFrame(
          now,
          isBlank(acpmuxPerf.mounted, scroller.scrollTop, scroller.clientHeight, scroller.scrollHeight),
        );
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      return scroller.scrollTop;
    });
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, -40);
      await page.evaluate(() => new Promise(requestAnimationFrame));
    }
    const measured = await page.evaluate(() => {
      const w = window as unknown as { __wheelFrames: number[]; __wheelRun: boolean };
      w.__wheelRun = false;
      const times = w.__wheelFrames;
      const debug = (window as unknown as { __debug: Debug }).__debug;
      return {
        times,
        finalTop: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
        perf: debug.perfStats(),
      };
    });
    if (measured.times.length < 2) throw new Error("scroll bench: wheel produced no frame intervals");
    if (measured.finalTop >= initialTop) throw new Error("scroll bench: wheel did not move the transcript upward");
    const duration_ms = measured.times.at(-1)! - measured.times[0];
    const frames = frameStats(measured.times, 1000 / HZ);
    return {
      ...frames,
      duration_ms,
      dropped_per_second: duration_ms > 0 ? (frames.dropped_frames * 1000) / duration_ms : 0,
      perf: measured.perf,
      coverage: await endCoverage(),
    };
  };

  // One warm-up of each, as the frame pacing bench's first fling.
  await fling();
  await wheel(60);
  const flings = [];
  const longScrolls = [];
  const wheels = [];
  for (let round = 0; round < ROUNDS; round += 1) {
    flings.push(await fling());
    longScrolls.push(await fling(15));
    wheels.push(await wheel(240));
  }
  // One short line per run and per span: CI logs cut long lines.
  const line = (name: string, frame: Frames, perf: Perf, coverage: ScrollCoverage | null) => {
    const pick = ({ p50_ms, p95_ms, max_ms }: Summary) => `${p50_ms}/${p95_ms}/${max_ms}`;
    console.log(
      `transcript-scroll-frame ${name}: frames=${frame.frames} interval=${frame.p50_ms}/${frame.p95_ms}/${frame.max_ms} ` +
        `dropped=${frame.dropped_frames} dropped_per_second=${frame.dropped_per_second} duration_ms=${frame.duration_ms} ` +
        `model_blank=${perf.blank_frames} react=${pick(perf.react)} ` +
        `layout=${pick(perf.layout)} other=${pick(perf.other)}`,
    );
    if (coverage) console.log(`transcript-scroll-frame ${name} painted_coverage=${JSON.stringify(coverage)}`);
    for (const [span, value] of Object.entries(perf.spans))
      console.log(`transcript-scroll-frame ${name} span ${span}=${pick(value)}`);
  };
  flings.forEach(({ fling, perf, coverage }, round) => line(`fling#${round}`, fling, perf, coverage));
  longScrolls.forEach(({ fling, perf, coverage }, round) => line(`long#${round}`, fling, perf, coverage));
  wheels.forEach(({ perf, coverage, ...frame }, round) => line(`wheel#${round}`, frame, perf, coverage));
  // The transcript's own work per frame (React, layout), median over rounds of each round's p50 and p95.
  // Frame intervals are left out: a headless runner's frame clock is not a display's.
  const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
  if (!COVERAGE)
    for (const [how, perfs] of [
      ["fling", flings.map((run) => run.perf)],
      ["long", longScrolls.map((run) => run.perf)],
      ["wheel", wheels.map((run) => run.perf)],
    ] as const)
      for (const kind of ["react", "layout"] as const)
        perfRow({
          name: `transcript_scroll.${how}.${kind}_ms`,
          p50: median(perfs.map((perf) => perf[kind].p50_ms)),
          p95: median(perfs.map((perf) => perf[kind].p95_ms)),
          target: TARGET_MS.frameWork,
        });
} finally {
  await browser.close();
  await vite.close();
}
