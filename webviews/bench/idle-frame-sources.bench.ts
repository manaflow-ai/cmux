// l10n-allow-file: benchmark output, not shipped UI.
// What the agent pane's always-on page parts cost while nothing on screen changes (CMUX-672, Leo: "idle cpu / ram
// optimization, get that as low to 0 as possible"; "idle gpu is def also relevant"). The page
// (bench/idle-frame-sources/main.tsx) is the pane's own stylesheets with its flicker detector, page-key mark and
// Chief dock, and one label whose text changes once a second, as a minute label or a presence row does in a chat at
// rest. After SETTLE_MS (the dock's greeting is over), each phase of PHASE_MS counts, from one browser-wide trace and
// the stability probe (bench/stability.ts):
//   frames       display frames the compositor drew for the page (trace `DrawFrame`), the GPU's share;
//   main frames  frames the page's main thread ran (`BeginMainThreadFrame`);
//   rAF          requestAnimationFrame callbacks, timers and other wakeups the page's script got;
//   animations   CSS animations still running at the window's end;
//   cpu ms       the renderer main thread's CPU time (CDP ThreadTime).
// Phases: `visible` (the page shown and key), `hidden` (document.visibilityState reads hidden and the page hears
// visibilitychange, as a page the app hides; Chromium itself keeps drawing it, as a page out of sight that never
// learned it was hidden did, cmux#43784).
//   bun bench/idle-frame-sources.bench.ts [phaseMs=10000]
// FRAME_WATCH=1 turns the flicker detector's frame watch on (its debug flag), to compare the cost it carries.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession } from "playwright";
import { chromium } from "./browsers";
import { perfRow } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, settledAt } from "./stability";

const PHASE_MS = Number(process.argv[2] ?? 10_000);
if (!Number.isInteger(PHASE_MS) || PHASE_MS < 1000) {
  console.error("usage: bun bench/idle-frame-sources.bench.ts [phaseMs=10000]");
  process.exit(2);
}
// Past the first-load watch's own bound (firstLoadWatch.ts WATCH_MS, 20 s on a page with no chat rows) and the dock's greeting.
const SETTLE_MS = 21_000;
const FRAME_WATCH = process.env.FRAME_WATCH === "1";
const webviews = path.resolve(import.meta.dir, "..");

type TraceEvent = { name: string; ph: string; pid: number; tid: number; args?: { data?: Record<string, unknown> } };

/// Counts the frame events of a browser-wide trace over a window (the page is the browser's only one): drawn frames and
/// main-thread frames.
async function traceFrames(cdp: CDPSession, run: () => Promise<unknown>): Promise<Map<string, number>> {
  const events: TraceEvent[] = [];
  const collect = (payload: { value: object[] }) => {
    for (const event of payload.value) events.push(event as TraceEvent);
  };
  cdp.on("Tracing.dataCollected", collect);
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: {
      includedCategories: [
        "__metadata",
        "devtools.timeline",
        "disabled-by-default-devtools.timeline",
        "disabled-by-default-devtools.timeline.frame",
        "cc",
      ],
      excludedCategories: ["*"],
    },
  });
  await run();
  const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
  await cdp.send("Tracing.end");
  await done;
  cdp.off("Tracing.dataCollected", collect);
  const counts = new Map<string, number>();
  for (const event of events) {
    if (event.name !== "DrawFrame" && event.name !== "BeginMainThreadFrame") continue;
    if (event.ph !== "X" && event.ph !== "B" && event.ph !== "I" && event.ph !== "i" && event.ph !== "b") continue;
    counts.set(event.name, (counts.get(event.name) ?? 0) + 1);
  }
  return counts;
}

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));
try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "idle-frame-sources-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: false,
    root: path.join(webviews, "bench/idle-frame-sources"),
    base: "./",
    esbuild: { jsx: "automatic" },
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  const context = await browser.newContext({ viewport: { width: 1000, height: 760 } });
  await addStabilityProbe(context, { boxes: false });
  if (FRAME_WATCH) await context.addInitScript(() => localStorage.setItem("cmux.diag.frameWatch", "on"));
  const page = await context.newPage();
  const cdp = await cpuSession(page, true);
  const tracing = await browser.newBrowserCDPSession();
  await page.goto(`http://127.0.0.1:${statics.port}/`);
  await page.waitForSelector(".acpmux-chief-dock-mascot img");
  // fixed-wait: the dock's greeting and the page's first load are not rest.
  await page.waitForTimeout(SETTLE_MS);
  await settledAt(page);

  const setHidden = (hidden: boolean) =>
    page.evaluate((value) => {
      Object.defineProperty(document, "visibilityState", { configurable: true, value: value ? "hidden" : "visible" });
      Object.defineProperty(document, "hidden", { configurable: true, value });
      document.dispatchEvent(new Event("visibilitychange"));
    }, hidden);

  console.log(
    `idle-frame-sources: ${PHASE_MS / 1000} s a phase after ${SETTLE_MS / 1000} s settle; frame watch ${FRAME_WATCH ? "on" : "off"}`,
  );
  console.log("phase | drawn frames/s | main frames/s | rAF/s | wakeups/s | running animations | cpu ms/s | sources");
  for (const phase of ["visible", "hidden"] as const) {
    await setHidden(phase === "hidden");
    // fixed-wait: the change's own frame lands before the window.
    await page.waitForTimeout(500);
    let idle: Awaited<ReturnType<typeof measureIdle>>[number] | undefined;
    const frames = await traceFrames(tracing, async () => {
      [idle] = await measureIdle([{ page, cdp }], PHASE_MS);
    });
    const seconds = PHASE_MS / 1000;
    const drawn = (frames.get("DrawFrame") ?? 0) / seconds;
    const main = (frames.get("BeginMainThreadFrame") ?? 0) / seconds;
    const cpu = (idle!.cpuMs ?? 0) / seconds;
    console.log(
      [
        phase,
        drawn.toFixed(1),
        main.toFixed(1),
        (idle!.frames / seconds).toFixed(1),
        (idle!.wakeups / seconds).toFixed(1),
        idle!.animations,
        cpu.toFixed(2),
        idle!.sources.slice(0, 4).join("; "),
      ].join(" | "),
    );
    const name = `idle_frame_sources${FRAME_WATCH ? ".frame_watch" : ""}.${phase}`;
    perfRow({ name: `${name}.drawn_frames_per_s`, p50: drawn, p95: drawn, target: 1, floor: 0, clock: "cpu" });
    perfRow({ name: `${name}.cpu_ms_per_s`, p50: cpu, p95: cpu, target: 2, floor: 0.5, clock: "cpu" });
  }
  await context.close();
} finally {
  await release();
}
