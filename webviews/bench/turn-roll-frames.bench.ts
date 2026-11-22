// Frame times across whole scripted turns (thinking, calls, text, end) on the send-stream-motion
// harness: the live line's roll before Leo's 2026-11-22 ask (liveSwap=opaque) against the shipped
// one (Leo: "i think ours is too jarring/jagged compared to claude right now"), one harness, one
// browser. Real clock, Chromium's own frames. Each look runs every scenario REPS times, alternating
// looks, at no throttle and at 4x CPU throttle. Reports p50/p95/p99 frame interval, dropped frames (an
// interval past a vsync, counted in vsyncs) and long animation frames (>50 ms).
//   cmux-ci test --setup playwright -- 'cd webviews && [REPS=3] bun bench/turn-roll-frames.bench.ts OUT.json'
import { writeFileSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const OUT = process.argv[2] ?? "turn-roll-bench.json";
const SCENARIOS = ["tools", "arrive-thinking", "arrive-tool", "thought-text", "text-tool", "burst-thought"];
const LOOKS = ["opaque", "shipped"];
const REPS = Number(process.env.REPS ?? 3);
const THROTTLES = [1, 4];

const { createServer } = await import("vite");
const webviews = process.cwd();
const vite = await createServer({
  root: webviews,
  configFile: path.join(webviews, "vite.config.ts"),
  mode: "production",
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  cacheDir: path.join(webviews, "node_modules/.vite-turn-roll-bench"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const { port } = vite.httpServer!.address() as { port: number };
const browser = await chromium.launch({ headless: true });

type Run = { look: string; scenario: string; throttle: number; intervals: number[]; laf: number[]; ms: number };
const runs: Run[] = [];
for (const throttle of THROTTLES)
  for (let rep = 0; rep < REPS; rep += 1)
    for (const scenario of SCENARIOS)
      for (const look of rep % 2 ? [...LOOKS].reverse() : LOOKS) {
        const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
        const swap = look === "shipped" ? "" : `&liveSwap=${look}`;
        await page.goto(`http://127.0.0.1:${port}/test/browser/send-stream-motion.html?rows=1${swap}`);
        await page.waitForFunction(() => "__sendStream" in window, null, { timeout: 60_000 });
        await page.waitForTimeout(500);
        const result = await page.evaluate(async (scenario) => {
          const intervals: number[] = [];
          const laf: number[] = [];
          let last = 0;
          let on = true;
          const loop = (t: number) => {
            if (last) intervals.push(t - last);
            last = t;
            if (on) requestAnimationFrame(loop);
          };
          requestAnimationFrame(loop);
          let observer: PerformanceObserver | undefined;
          try {
            observer = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) laf.push(entry.duration);
            });
            observer.observe({ type: "long-animation-frame", buffered: false });
          } catch {}
          const start = performance.now();
          await (window as any).__sendStream.run({ scenario });
          on = false;
          observer?.disconnect();
          return { intervals, laf, ms: performance.now() - start };
        }, scenario);
        runs.push({ look, scenario, throttle, ...result });
        await page.close();
      }
await browser.close();
await vite.close();

const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]! : NaN;
};
const summary: Record<string, unknown>[] = [];
for (const throttle of THROTTLES)
  for (const look of LOOKS) {
    const mine = runs.filter((run) => run.look === look && run.throttle === throttle);
    const all = mine.flatMap((run) => run.intervals);
    const vsync = pct(all, 10);
    const dropped = all.reduce((n, d) => n + Math.max(0, Math.round(d / vsync) - 1), 0);
    summary.push({
      throttle,
      look,
      frames: all.length,
      vsyncMs: +vsync.toFixed(2),
      p50: +pct(all, 50).toFixed(2),
      p95: +pct(all, 95).toFixed(2),
      p99: +pct(all, 99).toFixed(2),
      dropped,
      droppedPct: +((100 * dropped) / (all.length + dropped)).toFixed(2),
      longFrames: mine.reduce((n, run) => n + run.laf.length, 0),
      turnMs: +(mine.reduce((n, run) => n + run.ms, 0) / mine.length).toFixed(0),
    });
  }
console.table(summary);
writeFileSync(
  OUT,
  JSON.stringify(
    { summary, runs: runs.map(({ intervals, ...rest }) => ({ ...rest, frames: intervals.length })) },
    null,
    1,
  ),
);
