// l10n-allow-file: bench output labels, not shipped UI.
// Per-frame cost of a split divider dragged beside a long agent chat, in Chromium (the engine the
// app shows its chat in): the transcript harness (test/browser/transcript-fling.html) seeds TURNS
// synthetic turns, the view follows the latest row, and the chat's box takes a new width on every
// animation frame, as a pane does under a divider drag (one width step a frame, narrower, then wider
// again). Each frame records its main-thread work from the width write to the end of that frame's
// rendering step (style, layout, the transcript's ResizeObservers and the React renders they run,
// paint), read by a task posted from the frame's animation callback, which runs only once the
// rendering step finished. A frame whose work passes the display's frame budget shows the chat at
// its old width beside a pane already at the new one: the lag Leo saw (2026-11-11, "the dragging
// responsiveness is slow for agent chat but fast for browser hmmm").
// Runs at two transcript lengths: a drag frame's cost must not grow with the chat.
//   bun bench/transcript-resize-frame.bench.ts [turns=100,1500] [rounds=3]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { warmViteServer } from "../test/support/warmDevServer";
import { perfRow, TARGET_MS } from "./perfRow";

const TURNS = (process.argv[2] ?? "100,1500").split(",").map(Number);
const ROUNDS = Number(process.argv[3] ?? 3);
if (TURNS.some((turns) => !Number.isInteger(turns) || turns < 3) || !Number.isInteger(ROUNDS) || ROUNDS < 1)
  throw new Error("usage: transcript-resize-frame.bench.ts [turns>=3,...] [rounds>=1]");
const webviews = path.resolve(import.meta.dir, "..");
/// The drag: from WIDE to NARROW and back, STEPS frames each way.
const WIDE = 900;
const NARROW = 520;
const STEPS = 90;

const vite = await createServer({
  root: webviews,
  configFile: path.join(webviews, "vite.config.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const pagePath = "/test/browser/transcript-fling.html";
await warmViteServer(vite, pagePath);
const browser = await chromium.launch({ headless: true });
type Drag = {
  work: number[];
  intervals: number[];
  reactMs: number;
  layoutMs: number;
  spans: Record<string, number>;
  /// Frames where two mounted rows overlap on screen (a row drawn over the one under it).
  overlaps: number;
  /// The most the latest row's bottom moved from where it rested before the drag, over its frames.
  drift: number;
  /// How far the latest row's bottom moved from the drag's last frame to after the width held.
  settleJump: number;
};
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return Math.round((sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0) * 100) / 100;
};
try {
  const { port } = vite.httpServer!.address() as { port: number };
  for (const turns of TURNS) {
    const page = await browser.newPage({ viewport: { width: WIDE + 100, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}${pagePath}`);
    await page.waitForFunction(() => "__debug" in window);
    const seeded = await page.evaluate(`window.__debug.seedRows(${turns})`);
    const drag = async (): Promise<Drag> =>
      page.evaluate(
        async ({ wide, narrow, steps }) => {
          const perfUrl = "/src/agent-session/acpmux/perf.ts";
          type PerfModule = typeof import("../src/agent-session/acpmux/perf");
          const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
          const root = document.getElementById("root")!;
          root.style.width = `${wide}px`;
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = scroller.scrollHeight;
          for (let frame = 0; frame < 30; frame += 1) await new Promise(requestAnimationFrame);
          acpmuxPerf.enable();
          acpmuxPerf.resetFrames();
          const widths = [
            ...Array.from({ length: steps }, (_, i) => wide - ((wide - narrow) * (i + 1)) / steps),
            ...Array.from({ length: steps }, (_, i) => narrow + ((wide - narrow) * (i + 1)) / steps),
          ].map(Math.round);
          const work: number[] = [];
          const stamps: number[] = [];
          // Read once the frame rendered (layout is clean then: no read here forces one).
          const latestFoot = () => {
            const rows = scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row");
            const last = rows[rows.length - 1];
            return last ? scroller.getBoundingClientRect().bottom - last.getBoundingClientRect().bottom : 0;
          };
          const overlapping = () => {
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")];
            const boxes = rows.map((row) => row.getBoundingClientRect()).sort((a, b) => a.top - b.top);
            return boxes.some((box, i) => i > 0 && box.top < boxes[i - 1]!.bottom - 0.5);
          };
          const rest = latestFoot();
          let overlaps = 0;
          let drift = 0;
          let lastFoot = rest;
          await new Promise<void>((done) => {
            let index = 0;
            const tick = (now: number) => {
              stamps.push(now);
              acpmuxPerf.markFrame(now, false);
              if (index >= widths.length) return done();
              const start = performance.now();
              root.style.width = `${widths[index]}px`;
              index += 1;
              const channel = new MessageChannel();
              channel.port1.onmessage = () => {
                work.push(performance.now() - start);
                lastFoot = latestFoot();
                drift = Math.max(drift, Math.abs(lastFoot - rest));
                if (overlapping()) overlaps += 1;
              };
              channel.port2.postMessage(0);
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          });
          // Let the last frame's task land, then the width hold and the rows be placed at it.
          await new Promise((resolve) => setTimeout(resolve, 50));
          const stats0 = acpmuxPerf.stats();
          await new Promise((resolve) => setTimeout(resolve, 400));
          for (let frame = 0; frame < 3; frame += 1) await new Promise(requestAnimationFrame);
          const settleJump = Math.abs(latestFoot() - lastFoot);
          if (overlapping()) overlaps += 1;
          const stats = stats0 as unknown as {
            react?: { p95_ms: number };
            layout?: { p95_ms: number };
            spans?: Record<string, { p95_ms: number }>;
          };
          const intervals = stamps.slice(1).map((t, i) => t - stamps[i]!);
          return {
            work,
            intervals,
            reactMs: stats.react?.p95_ms ?? 0,
            layoutMs: stats.layout?.p95_ms ?? 0,
            spans: Object.fromEntries(Object.entries(stats.spans ?? {}).map(([k, v]) => [k, v.p95_ms])),
            overlaps,
            drift: Math.round(drift * 10) / 10,
            settleJump: Math.round(settleJump * 10) / 10,
          };
        },
        { wide: WIDE, narrow: NARROW, steps: STEPS },
      );
    await drag(); // warm-up
    const drags: Drag[] = [];
    for (let round = 0; round < ROUNDS; round += 1) drags.push(await drag());
    // CMUX_RESIZE_PROFILE=1: one more drag under the CPU profiler, its heaviest functions by self time.
    if (process.env.CMUX_RESIZE_PROFILE === "1") {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
      await drag();
      const { profile } = (await cdp.send("Profiler.stop")) as {
        profile: {
          nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
          samples: number[];
          timeDeltas: number[];
        };
      };
      const byNode = new Map(profile.nodes.map((node) => [node.id, node.callFrame]));
      const self = new Map<string, number>();
      profile.samples.forEach((id, index) => {
        const frame = byNode.get(id)!;
        const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").slice(-2).join("/").split("?")[0]}:${frame.lineNumber + 1}`;
        self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
      });
      for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 30))
        console.log(`transcript-resize-frame turns=${turns} profile self_ms=${ms.toFixed(1)} ${key}`);
    }
    console.log(`transcript-resize-frame turns=${turns} fixture=${JSON.stringify(seeded)}`);
    drags.forEach((run, round) => {
      const budget = 1000 / 60;
      const over = run.work.filter((ms) => ms > budget).length;
      const dropped = run.intervals.filter((ms) => ms > budget * 1.5).length;
      console.log(
        `transcript-resize-frame turns=${turns} drag#${round}: frames=${run.work.length} ` +
          `work_ms p50/p95/max=${pct(run.work, 0.5)}/${pct(run.work, 0.95)}/${pct(run.work, 1)} ` +
          `over_budget=${over} dropped=${dropped} interval_p95=${pct(run.intervals, 0.95)} react_p95=${run.reactMs} layout_p95=${run.layoutMs} ` +
          `overlap_frames=${run.overlaps} latest_drift_px=${run.drift} settle_jump_px=${run.settleJump} ` +
          `spans_p95=${JSON.stringify(run.spans)}`,
      );
    });
    perfRow({
      name: `transcript_resize.t${turns}.work_ms`,
      p50: median(drags.map((run) => pct(run.work, 0.5))),
      p95: median(drags.map((run) => pct(run.work, 0.95))),
      target: TARGET_MS.frameWork,
    });
    await page.close();
  }
} finally {
  await browser.close();
  await vite.close();
}
