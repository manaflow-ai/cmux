// Glass candy perf note (not committed): per variant, under 4x CPU throttling and the gallery's load=busy,
// the frame gaps and Long Tasks during entry and during a pointer sweep; then, with no load, the idle
// cost: rAF callbacks scheduled and running animations over 2 s at rest.
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

const ENTRY = "ui.glass-candy";
const VARIANTS = ["plain-starry", "refraction-starry", "depth-starry", "art-tint-starry", "refraction-busy", "depth-lens-starry"];
const RUNS = Number(process.env.RUNS ?? 3);
const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch({ headless: true, args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "plain-starry" } });
const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;

const INIT = () => {
  const w = window as unknown as Record<string, unknown>;
  const gaps: number[] = [];
  const longTasks: number[] = [];
  let pageRaf = 0;
  const raf = window.requestAnimationFrame.bind(window);
  // Count rAF requests by page code (the probe's own loop uses `raf` directly).
  window.requestAnimationFrame = (cb) => {
    pageRaf += 1;
    return raf(cb);
  };
  let last = 0;
  let recording = false;
  const tick = (now: number) => {
    if (recording && last) gaps.push(now - last);
    last = now;
    if (recording) raf(tick);
  };
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) if (recording) longTasks.push(entry.duration);
  }).observe({ type: "longtask", buffered: false });
  w.__probe = {
    start() {
      gaps.length = 0;
      longTasks.length = 0;
      last = 0;
      recording = true;
      raf(tick);
    },
    stop() {
      recording = false;
      return { gaps: [...gaps], longTasks: [...longTasks] };
    },
    raf: () => pageRaf,
    running: () => document.getAnimations().filter((animation) => animation.playState === "running").length,
    lens: () => !!document.querySelector("canvas[data-cmux-glass-lens]"),
  };
};

const pct = (values: number[], p: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
};

type Row = Record<string, number | string | boolean>;
const rows: Row[] = [];
for (const variant of VARIANTS)
  for (let run = 0; run < RUNS; run += 1) {
    for (const load of ["busy", "none"] as const) {
      const page = await browser.newPage({ viewport: { width: 760, height: 520 } });
      await page.addInitScript(INIT);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
      await page.goto(
        base + galleryFrame(ENTRY, { variant, width: 760, height: 520, frame: "component", ...(load === "busy" ? { load } : {}) }),
      );
      // Entry: from the first content frame to settled.
      await page.waitForSelector(".candy-stage[data-candy]", { timeout: 90_000 });
      await page.evaluate(() => (window as any).__probe.start());
      await page.waitForSelector(".candy-stage[data-settled]", { timeout: 30_000 });
      await page.waitForTimeout(300);
      const entry = await page.evaluate(() => (window as any).__probe.stop());
      // Interaction: one pointer sweep across the stage, ~1 s.
      await page.mouse.move(20, 20);
      await page.evaluate(() => (window as any).__probe.start());
      await page.mouse.move(720, 480, { steps: 40 });
      await page.mouse.move(40, 300, { steps: 30 });
      await page.waitForTimeout(400);
      const sweep = await page.evaluate(() => (window as any).__probe.stop());
      // Idle: pointer gone, let everything settle, then 2 s at rest.
      await page.mouse.move(-10, -10);
      await page.waitForTimeout(1500);
      const before = await page.evaluate(() => (window as any).__probe.raf());
      await page.waitForTimeout(2000);
      const idle = await page.evaluate(() => ({
        raf: (window as any).__probe.raf(),
        running: (window as any).__probe.running(),
        lens: (window as any).__probe.lens(),
      }));
      if (load === "busy")
        rows.push({
          variant,
          run,
          load,
          entryP50: +pct(entry.gaps, 50).toFixed(1),
          entryP95: +pct(entry.gaps, 95).toFixed(1),
          entryMax: +Math.max(0, ...entry.gaps).toFixed(1),
          entryLong: entry.longTasks.length,
          sweepP50: +pct(sweep.gaps, 50).toFixed(1),
          sweepP95: +pct(sweep.gaps, 95).toFixed(1),
          sweepMax: +Math.max(0, ...sweep.gaps).toFixed(1),
          sweepFrames: sweep.gaps.length,
          sweepLong: sweep.longTasks.length,
        });
      else rows.push({ variant, run, load, idleRaf: idle.raf - before, idleRunning: idle.running, lens: idle.lens });
      await page.close();
    }
  }
console.log("PERF-JSON " + JSON.stringify(rows));
await browser.close();
await vite.close();
