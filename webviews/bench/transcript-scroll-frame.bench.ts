// l10n-allow-file: bench output labels, not shipped UI.
// Per-frame cost of scrolling a long agent chat in real WebKit: the transcript harness
// (test/browser/transcript-fling.html) seeds ROWS synthetic rows, then a reader scrolls it two
// ways: the debug fling (debug.ts startFling, the frame pacing bench's fling, one scrollTop step
// per animation frame) and trackpad wheel input (page.mouse.wheel, 40 px a step, a step a frame),
// the slow reading scroll where a hitch shows. Prints, for each, frame intervals (p50/p95/max,
// dropped frames) and the transcript's own per-frame work (acpmuxPerf: React, layout, spans,
// vt.renders = renders of VirtualTranscript per frame).
//   bun bench/transcript-scroll-frame.bench.ts [rows=3000] [rounds=3]
// Each line: interval, react, layout and other are p50/p95/max ms per frame.
/// <reference types="bun" />
import path from "node:path";
import { webkit } from "playwright";
import { createServer } from "vite";
import { warmViteServer } from "../test/support/warmDevServer";

const ROWS = Number(process.argv[2] ?? 3000);
const ROUNDS = Number(process.argv[3] ?? 3);
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
  await page.goto(`http://127.0.0.1:${port}${pagePath}`);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(${ROWS})`);
  await page.locator(".acpmux-scroll").hover();

  type Debug = {
    startFling(seconds: number, options: { wait: boolean; nominal_ms?: number }): Promise<Record<string, unknown>>;
    perfStats(): Record<string, unknown>;
  };
  const fling = () =>
    page.evaluate(async () => {
      const debug = (window as unknown as { __debug: Debug }).__debug;
      const fling = await debug.startFling(3, { wait: true, nominal_ms: 1000 / 60 });
      return { fling, perf: debug.perfStats() };
    });
  // Wheel: from the latest message upward, one 40 px step a frame for `steps` frames. The frames
  // are marked into acpmuxPerf (the same module instance the page runs, through Vite) as the
  // fling marks its own.
  const wheel = async (steps: number) => {
    await page.evaluate(async () => {
      const { acpmuxPerf } = await import("/src/agent-session/acpmux/perf.ts");
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
        acpmuxPerf.markFrame(now, false);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, -40);
      await page.evaluate(() => new Promise(requestAnimationFrame));
    }
    return page.evaluate(() => {
      const w = window as unknown as { __wheelFrames: number[]; __wheelRun: boolean };
      w.__wheelRun = false;
      const times = w.__wheelFrames;
      const gaps = times
        .slice(1)
        .map((time, at) => time - times[at])
        .sort((a, b) => a - b);
      const at = (p: number) =>
        Math.round((gaps[Math.min(gaps.length - 1, Math.floor(p * gaps.length))] ?? 0) * 100) / 100;
      const debug = (window as unknown as { __debug: Debug }).__debug;
      return {
        frames: times.length,
        p50_ms: at(0.5),
        p95_ms: at(0.95),
        max_ms: at(1),
        over_25ms: gaps.filter((gap) => gap > 25).length,
        perf: debug.perfStats(),
      };
    });
  };

  // One warm-up of each, as the frame pacing bench's first fling.
  await fling();
  await wheel(60);
  const flings = [];
  const wheels = [];
  for (let round = 0; round < ROUNDS; round += 1) {
    flings.push(await fling());
    wheels.push(await wheel(240));
  }
  // One short line per run and per span: CI logs cut long lines.
  const line = (name: string, frame: Record<string, unknown>, perf: Record<string, unknown>) => {
    const pick = (value: unknown) => {
      const { p50_ms, p95_ms, max_ms } = value as Record<string, number>;
      return `${p50_ms}/${p95_ms}/${max_ms}`;
    };
    console.log(
      `transcript-scroll-frame ${name}: frames=${frame.frames} interval=${frame.p50_ms}/${frame.p95_ms}/${frame.max_ms} ` +
        `dropped=${frame.dropped_frames ?? frame.over_25ms} blank=${perf.blank_frames} react=${pick(perf.react)} ` +
        `layout=${pick(perf.layout)} other=${pick(perf.other)}`,
    );
    for (const [span, value] of Object.entries(perf.spans as Record<string, unknown>))
      console.log(`transcript-scroll-frame ${name} span ${span}=${pick(value)}`);
  };
  flings.forEach(({ fling, perf }, round) => line(`fling#${round}`, fling, perf));
  wheels.forEach(({ perf, ...frame }, round) => line(`wheel#${round}`, frame, perf));
} finally {
  await browser.close();
  await vite.close();
}

