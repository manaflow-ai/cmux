// l10n-allow-file: benchmark output, not shipped UI.
// Layout stability and idle cost of the web UI surfaces the gallery renders headlessly (bench/stability.ts):
// per surface, in Chromium and WebKit, how long until nothing moves, how much moved (CLS-style), and how often the
// page still wakes once it is still (Leo, 2026-11-03: "things should be instant and not shift layouts AND not take
// many resources"). It builds the static gallery once (vite.config.gallery.ts), serves it, and opens each surface's
// stage (frame.html?entry=…&variant=…) in a fresh browser context per round:
//   open   the stage's mount: settled from navigation start, CLS from the gallery's load report (frame/main.ts);
//   play   the variant's play steps (a menu or picker opening): settled from the last step's start, CLS from the
//          play report's steps (frame/playRunner.ts).
// The last round's page stays open, and every surface of an engine then sits through one shared IDLE_MS window
// (each page counts its own wakeups; Chromium's task time is per page's renderer).
// Rows (bench/perfRow.ts): ui.<surface>[.webkit].settled, .settle_after_paint (open: first paint to settled),
// .cls, .idle_wakeups, and Chromium's .idle_cpu_ms.
//   bun bench/ui-stability.bench.ts [rounds=3] [--only surface,surface]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type CDPSession, type Page } from "playwright";
import { perfRow, TARGET_MS } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, median, settledAt, IDLE_MS, type Idle } from "./stability";

const argv = process.argv.slice(2);
const onlyAt = argv.indexOf("--only");
const only = onlyAt >= 0 ? argv[onlyAt + 1]?.split(",") : undefined;
const ROUNDS = Number(argv.find((arg, index) => /^\d+$/.test(arg) && argv[index - 1] !== "--only") ?? 3);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1) {
  console.error("usage: bun bench/ui-stability.bench.ts [rounds=3] [--only surface,surface]");
  process.exit(2);
}

type Surface = { name: string; entry: string; variant: string; kind: "open" | "play"; width?: number };
/// One stage per surface Leo holds to the rail's bar (transcript, composer, menus, picker, rail, Session Info,
/// Home, New Tab). Chat switch and the transcript's cold open in the production pane are chat-switch.bench.ts's.
const SURFACES: readonly Surface[] = [
  { name: "transcript", entry: "agent-pane.transcript", variant: "conversation", kind: "open" },
  { name: "composer", entry: "agent-pane.composer", variant: "new-chat", kind: "open" },
  { name: "thread_rail", entry: "agent-pane.thread-minimap", variant: "first-paint", kind: "open" },
  { name: "thread_rail_preview", entry: "agent-pane.thread-minimap", variant: "card-metadata", kind: "play" },
  { name: "chat_rail", entry: "agent-pane.chat-minimap", variant: "at-rest", kind: "open" },
  { name: "new_tab", entry: "agent-pane.new-tab-page", variant: "idle", kind: "open" },
  { name: "home", entry: "pages.home-channels", variant: "normal", kind: "open" },
  // At 528 px the pane is too narrow to keep Session Info open beside the chat, so its play clicks the toggle.
  { name: "session_info", entry: "agent-pane.session-info-narrow-pane", variant: "opened", kind: "play", width: 528 },
  { name: "model_picker", entry: "agent-pane.model-picker", variant: "idle", kind: "play" },
  { name: "quick_model_menu", entry: "new-tab.quick-model-menu", variant: "in-chat", kind: "play" },
  { name: "options_menu", entry: "agent-pane.options-menu", variant: "one-open", kind: "play" },
];
const unknown = only?.filter((name) => !SURFACES.some((surface) => surface.name === name)) ?? [];
if (unknown.length) {
  console.error(`ui-stability: unknown surface ${unknown.join(", ")}`);
  process.exit(2);
}
const surfaces = SURFACES.filter((surface) => !only || only.includes(surface.name));

type Step = { action: string; settleMs: number; layoutShift: number; boxShift?: number };
type Reports = {
  ready: string | undefined;
  load?: { layoutShift: number; boxShift: number; shifts: { value: number; sources: string[] }[] };
  play?: { status: string; steps: Step[]; error?: string };
};
/** settled from navigation (open) or the last step's start (play); afterPaint from the stage's first paint (open). */
type Round = { settled: number; afterPaint?: number; cls: number; shifted: string[] };

const webviews = path.resolve(import.meta.dir, "..");
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

/** One round of one surface; the page and its CDP session when `keep`, for the idle window. */
async function round(
  browser: Browser,
  isChromium: boolean,
  base: string,
  surface: Surface,
  keep: boolean,
): Promise<Round & { kept?: { page: Page; cdp: CDPSession | null } }> {
  const context = await browser.newContext({
    viewport: { width: surface.width ?? 1200, height: 800 },
    colorScheme: "dark",
  });
  // The stage's first paint: its root holds the surface, no longer the "Loading …" placeholder (frame/main.ts).
  await addStabilityProbe(context, {
    content: "#root:not(.gallery-frame-loading) > *",
    traceBoxes: process.env.CMUX_STABILITY_TRACE === "1",
  });
  const page = await context.newPage();
  const cdp = await cpuSession(page, isChromium);
  try {
    await page.goto(
      `${base}/frame.html?entry=${surface.entry}&variant=${surface.variant}&colorScheme=dark&width=normal`,
      { waitUntil: "domcontentloaded" },
    );
    await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""), {
      timeout: 90_000,
      polling: 100,
    });
    // Ready means the stage held still for 250 ms (frame/main.ts); a second more catches a late move.
    await page.waitForTimeout(1000);
    const { lastChange, firstContent, actionStarts, boxChanges } = await settledAt(page);
    if (boxChanges)
      console.log(
        `BOX_TRACE ${JSON.stringify({ engine: isChromium ? "chromium" : "webkit", surface: surface.name, firstContent, lastChange, boxChanges })}`,
      );
    const reports = await page.evaluate((): Reports => ({
      ready: document.documentElement.dataset.galleryReady,
      load: (window as unknown as { cmuxGalleryLoadReport?: Reports["load"] }).cmuxGalleryLoadReport,
      play: (window as unknown as { cmuxGalleryPlayReport?: Reports["play"] }).cmuxGalleryPlayReport,
    }));
    if (reports.ready !== "1") throw new Error(`${surface.entry}#${surface.variant}: the stage failed`);
    const cls = (shift: { layoutShift: number; boxShift?: number }) =>
      isChromium ? shift.layoutShift : (shift.boxShift ?? 0);
    let result: Round;
    if (surface.kind === "open") {
      if (!reports.load) throw new Error(`${surface.entry}: no load report`);
      // The stage's body growing from its "Loading …" line to the mounted surface is the frame's, not the
      // surface's: nothing that was drawn moves. Every other shift of the load counts.
      const own = reports.load.shifts.filter((shift) => shift.sources.some((source) => source !== "body"));
      result = {
        settled: lastChange,
        afterPaint: firstContent ? Math.max(0, lastChange - firstContent) : lastChange,
        cls: isChromium ? own.reduce((sum, shift) => sum + shift.value, 0) : reports.load.boxShift,
        shifted: reports.load.shifts.map((shift) => `${shift.value.toFixed(4)} ${shift.sources.join(" ")}`),
      };
    } else {
      const steps = reports.play?.steps ?? [];
      let last = steps.length - 1;
      while (last >= 0 && steps[last]!.action === "wait") last -= 1;
      if (last < 0)
        throw new Error(`${surface.entry}#${surface.variant}: no play step (${reports.play?.error ?? "none"})`);
      const start = actionStarts[last];
      const acted = steps.filter((step) => step.action !== "wait");
      result = {
        settled: start === undefined ? steps[last]!.settleMs : Math.max(0, lastChange - start),
        cls: acted.reduce((sum, step) => sum + cls(step), 0),
        shifted: [],
      };
    }
    if (keep) return { ...result, kept: { page, cdp } };
    await context.close();
    return result;
  } catch (error) {
    await context.close();
    throw error;
  }
}

try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "ui-stability-gallery-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const builtAt = performance.now();
  // `gallery:build` (package.json): the generated strings, then the static gallery.
  const strings = Bun.spawnSync(["node", "scripts/pages/gen-strings.mjs"], { cwd: webviews, stdout: "ignore" });
  if (strings.exitCode !== 0) throw new Error(`gen-strings exited ${strings.exitCode}: ${strings.stderr.toString()}`);
  process.env.CMUX_GALLERY_OUT_DIR = out;
  const { build } = await import("vite");
  await build({ root: webviews, configFile: path.join(webviews, "vite.config.gallery.ts"), logLevel: "error" });
  console.log(`ui-stability: gallery built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = decodeURIComponent(new URL(request.url).pathname);
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const base = `http://127.0.0.1:${statics.port}`;

  let failed = 0;
  for (const [engine, type] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    const isChromium = engine === "chromium";
    const browser = await type.launch({ headless: true });
    releases.push(() => browser.close());
    const suffix = isChromium ? "" : ".webkit";
    const kept: { surface: Surface; page: Page; cdp: CDPSession | null; rounds: Round[] }[] = [];
    for (const surface of surfaces) {
      const rounds: Round[] = [];
      try {
        // A first, unmeasured open (per engine) warms the server and the browser process.
        if (surface === surfaces[0]) await round(browser, isChromium, base, surface, false);
        for (let index = 0; index < ROUNDS; index++) {
          const got = await round(browser, isChromium, base, surface, index === ROUNDS - 1);
          rounds.push(got);
          if (got.kept) kept.push({ surface, ...got.kept, rounds });
        }
      } catch (error) {
        failed += 1;
        console.log(
          `ui-stability: ${engine} ${surface.name} FAILED: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
    const idle: Idle[] = await measureIdle(kept);
    console.log(`ui-stability: ${engine}, median of ${ROUNDS}; idle over one ${IDLE_MS / 1000} s window`);
    console.log("surface | settled ms | cls | idle wakeups (timeouts intervals frames idle animations) | idle cpu ms");
    for (const [index, { surface, rounds }] of kept.entries()) {
      const settled = median(rounds.map((r) => r.settled));
      // Shifts under 0.0001 are layout rounding: the row reads 0 then.
      const cls = Math.round(median(rounds.map((r) => r.cls)) * 1e4) / 1e4;
      const quiet = idle[index]!;
      console.log(
        `${surface.name} | ${settled.toFixed(0)} | ${cls.toFixed(4)} | ${quiet.wakeups} (${quiet.timeouts} ${quiet.intervals} ` +
          `${quiet.frames} ${quiet.idleCallbacks} ${quiet.animations}) | ${quiet.cpuMs === null ? "-" : quiet.cpuMs.toFixed(1)}` +
          (quiet.pageLoops === null ? "" : ` | page loops ${quiet.pageLoops}`),
      );
      for (const source of quiet.sources.slice(0, 12)) console.log(`  woke: ${source}`);
      for (const shift of rounds.at(-1)!.shifted.slice(0, 4)) console.log(`  shifted: ${shift}`);
      const name = `ui.${surface.name}${suffix}`;
      const target = surface.kind === "open" ? TARGET_MS.load : TARGET_MS.response;
      perfRow({ name: `${name}.settled`, p50: settled, p95: settled, target });
      if (surface.kind === "open") {
        // First paint to settled: 0 when the first frame is the final frame; the target allows that one frame.
        const afterPaint = median(rounds.map((r) => r.afterPaint ?? 0));
        console.log(`  first paint to settled: ${afterPaint.toFixed(0)} ms`);
        perfRow({ name: `${name}.settle_after_paint`, p50: afterPaint, p95: afterPaint, target: 17, floor: 17 });
      }
      // A target of zero: a still page shifts nothing and wakes nothing. The floor keeps a rounding-sized change noise.
      perfRow({ name: `${name}.cls`, p50: cls, p95: cls, unit: "score", target: 0, floor: 0.001 });
      perfRow({
        name: `${name}.idle_wakeups`,
        p50: quiet.wakeups,
        p95: quiet.wakeups,
        unit: "count",
        target: 0,
        floor: 0.5,
      });
      if (quiet.cpuMs !== null)
        perfRow({ name: `${name}.idle_cpu_ms`, p50: quiet.cpuMs, p95: quiet.cpuMs, target: 5, floor: 2 });
    }
    for (const { page } of kept) await page.context().close();
  }
  if (failed) process.exitCode = 1;
} finally {
  await release();
}
