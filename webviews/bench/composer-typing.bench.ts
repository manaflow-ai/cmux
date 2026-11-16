// l10n-allow-file: benchmark output, not shipped UI.
// What one keystroke in the agent chat's composer costs, and what it costs under load (CMUX-571, Leo: "improve
// performance (chat, everything related)"; Leo, 2026-11-12: long chats must have "no perceivable difference"; Leo,
// 2026-11-16: "but typing under load is not good enough", with a recording of composer keys landing in bursts while
// agents ran). A key should render the composer and nothing that does not read its text: not the pane root, not the
// transcript, not a row; its cost should not grow with the transcript, and it should not grow with what else runs.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), built as it ships (the server
// setup below). Each row is one load mode at one transcript length: a light chat
// (`cmuxAcpmuxDebug.loadSeed(turns, { light: true })`), the mode's load put on, then `--keys` letters typed into the
// prompt with real key events (Playwright's keyboard, `--gap` ms apart, about a fast typist's pace).
//
// The load modes are the shared set every under-load harness uses (bench/load-modes.json, cmuxterm-hq
// docs/design/chat-instant-under-load.md "The bench"), so a typing number and a tab-switch number were taken under
// the same load:
//   L0 idle                      L3 the focused chat is the 100k-row fixture, streaming
//   L1 the focused chat streams  L4 every core saturated by other processes
//   L2 10 other chats streaming  L5 L1 to L4 together
// `--modes all` runs every one; `idle` and `stream` still mean L0 and L1. A page harness has no terminals and no
// workspaces, so L5's 20 printing terminals and 60 workspaces are `missing` on these rows (the native harness,
// scripts/cmux-next/typing-frame-bench.py, has them); each row prints what its mode could not express.
//
// Per key:
//   renders   `acpmuxPerf.renders`: the pane root (AcpmuxPane), the transcript, the composer, every row and row frame
//   layout    the page's layouts and style recalcs (CDP Performance.getMetrics LayoutCount, RecalcStyleCount)
//   script    main-thread script, layout and style time (ScriptDuration, LayoutDuration, RecalcStyleDuration), ms
// Per row (the keystroke-to-paint numbers the design gates at p95 16 ms):
//   to_frame  the page's own typingStats (keydown to the next frame, p50 / p95 / p99 / max), as the Mac bench reads it
//   longest_task_ms, long_tasks   the page main thread's long tasks over the typed keys (Chromium only)
//   frames_over_16ms              frames whose interval missed a 60 Hz frame while the keys were typed
//   keys_sharing_a_frame          keys that landed in the same frame as another key: a burst
//   load                          how much longer CPU-bound work took on this host during the row than on it idle
//                                 (bench/hostLoad.ts): 1 idle, well above 1 in L4 and L5, so a row proves its load
//   stream    with a streaming mode, and with no typing, the composer's renders per streamed event (reply text and
//             tool calls, then a tool's output ticking while another chat changes: debug loadRun and loadTick). A
//             stream event the composer does not show should render it 0 times.
//
//   bun bench/composer-typing.bench.ts [--lengths 60,1500,6000] [--modes L0,L1,L2,L3,L4,L5|all] [--keys 60]
//       [--gap 80] [--engines chromium,webkit] [--gate-p95-ms 16] [--dev] [--profile]
//
// --gate-p95-ms exits 1 when a measured mode's key-to-frame p95 is over it (16 ms is the design's target). It is a
// flag of this bench, never a CI gate (cmux CLAUDE.md: "Never add CI gates, perf-gate rows or budgets").
//
// Where it runs: Linux (`cmux-ci test --setup playwright -- 'cd webviews && bun bench/composer-typing.bench.ts
// --modes all'`), never by hand on a Mac: no Playwright or downloaded browser belongs on Leo's Mac or a fleet Mac
// (test/support/systemChrome.ts, which rejects every launch there with NO_PLAYWRIGHT_ON_MACS). So `--engines webkit`
// resolves only inside a macOS Actions job, where that refusal lifts; the Mac arm of these numbers is the native
// harness, scripts/cmux-next/typing-frame-bench.py --modes, which types into the app itself.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";
import type { Browser, Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";
import {
  GATE_P95_MS,
  TYPING_PROBE_SCRIPT,
  focusedStreamOptions,
  loadFactor,
  openOtherChats,
  parseModes,
  startCpuBurners,
  summarizeTypingProbe,
  turnsForRows,
  type LoadMode,
} from "./loadModes";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "60,1500,6000").split(",").map(Number);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
const MODES = parseModes(flag("--modes"), "L0");
const ENGINES = (flag("--engines") ?? "chromium").split(",").map((name) => name.trim()) as ("chromium" | "webkit")[];
const GATE_P95 = flag("--gate-p95-ms") === undefined ? undefined : Number(flag("--gate-p95-ms"));
/// With --profile: a CPU profile over the typed keys, and the functions with the most time per key (inclusive and self).
const PROFILE = argv.includes("--profile");
const DEV = argv.includes("--dev");
const webviews = path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const METRICS = [
  "LayoutCount",
  "RecalcStyleCount",
  "ScriptDuration",
  "LayoutDuration",
  "RecalcStyleDuration",
  "TaskDuration",
] as const;
/// A mode that streams needs the stream to outlive the typed keys; the seconds the run asks for.
const RUN_SECONDS = (KEYS * (GAP_MS + 20)) / 1000 + 1;

async function openChat(page: Page, port: number, turns: number) {
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 120_000 });
  return seeded.rows as number;
}

type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples: number[];
  timeDeltas: number[];
};

/// Per key, ms: each function's inclusive time (once per sample however deep it recurses) and self time.
function printProfile(label: string, profile: CpuProfile) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const name = (id: number) => {
    const frame = byId.get(id)!.callFrame;
    const file = frame.url.split("/").pop()?.split("?")[0] ?? "";
    return `${frame.functionName || "(anon)"} ${file}:${frame.lineNumber + 1}`;
  };
  const inclusive = new Map<string, number>();
  const self = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const ms = (profile.timeDeltas[index + 1] ?? 0) / 1000;
    const fn = byId.get(id)?.callFrame.functionName;
    if (fn === "(idle)" || fn === "(program)") return;
    self.set(name(id), (self.get(name(id)) ?? 0) + ms);
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const key = name(at);
      if (seen.has(key)) continue;
      seen.add(key);
      inclusive.set(key, (inclusive.get(key) ?? 0) + ms);
    }
  });
  const top = (map: Map<string, number>, count: number) =>
    [...map.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key, ms]) => `  ${(ms / KEYS).toFixed(3)} ms/key  ${key}`)
      .join("\n");
  console.log(`PROFILE ${label}, inclusive:\n${top(inclusive, 90)}`);
  console.log(`PROFILE ${label}, self:\n${top(self, 40)}`);
}

// The pane as it ships (a vite build: production React, the React Compiler pass), served as files; --dev serves the
// dev server's pane instead (development React, several times the script time per render). With --profile the build
// is unminified, so the profile names functions.
const releases: (() => unknown)[] = [];
let port: number;
if (DEV) {
  const { createServer } = await import("vite");
  const vite = await createServer({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  releases.push(() => vite.close());
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  port = (vite.httpServer!.address() as { port: number }).port;
} else {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-typing-bench-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false } : {}) },
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
  port = statics.port!;
}

/// The rows a mode measures at: its own pinned transcript (L3 and L5's god chat) or the harness's length axis.
function rowsFor(mode: LoadMode, lengths: number[]): number[] {
  return mode.web.rows === null ? lengths : [mode.web.rows];
}

type Row = Record<string, unknown>;

/// One row: a chat of `length` rows in `engine`, under `mode`, with `KEYS` keys typed into the composer.
async function measure(browser: Browser, engine: "chromium" | "webkit", mode: LoadMode, length: number): Promise<Row> {
  const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
  await page.addInitScript(TYPING_PROBE_SCRIPT);
  const rows = await openChat(page, port, turnsForRows(length));
  // CDP's metrics are Chromium's; a WebKit row reports the keystroke numbers and leaves them out.
  const cdp = engine === "chromium" ? await page.context().newCDPSession(page) : undefined;
  if (cdp) await cdp.send("Performance.enable");
  const metrics = async () => {
    if (!cdp) return {} as Record<string, number>;
    const { metrics: list } = (await cdp.send("Performance.getMetrics")) as {
      metrics: { name: string; value: number }[];
    };
    return Object.fromEntries(
      list.filter((m) => (METRICS as readonly string[]).includes(m.name)).map((m) => [m.name, m.value]),
    );
  };
  await page.locator(PROMPT).first().click();
  // Warm-up: the first keys load the composer's lazy parts (emoji data, the mention index).
  for (const key of "warm") await page.keyboard.press(key);
  await page.waitForTimeout(500);
  for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
  await page.waitForTimeout(500);
  await page.evaluate(() => {
    const debug = (window as any).cmuxAcpmuxDebug;
    debug.resetTyping();
    debug.renders();
  });

  // The mode's load, put on after the warm-up and taken off after the keys, so the page is set up on an idle host
  // and only the measured keys run under it.
  // The other chats' streams start before the keys do (their pages open and seed first), so they get the typing
  // window plus the margin that setup takes, and stream for all of it.
  const others = mode.web.otherChats
    ? await openOtherChats(browser, port, mode.web.otherChats, mode.web.otherChatChunksPerSecond, RUN_SECONDS + 5)
    : undefined;
  const burners = mode.web.cpuSaturation ? startCpuBurners() : undefined;
  try {
    if (PROFILE && cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    // A streaming mode: the focused chat streams for the whole typing run (no scrolling).
    const streaming = mode.web.focusedStream
      ? page.evaluate(
          (options) => (window as any).cmuxAcpmuxDebug.loadRun(options),
          focusedStreamOptions(mode.web.focusedStream, RUN_SECONDS),
        )
      : Promise.resolve(undefined);
    if (mode.web.focusedStream || others) {
      await page.waitForTimeout(300);
      await page.evaluate(() => {
        const debug = (window as any).cmuxAcpmuxDebug;
        debug.resetTyping();
        debug.renders();
      });
    }
    const before = await metrics();
    await page.evaluate(() => (window as any).__benchTypingLoad.start());
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (let i = 0; i < KEYS; i += 1) {
      await page.keyboard.press(letters[i % letters.length]!);
      await page.waitForTimeout(GAP_MS);
    }
    // The host's contention while the load is still on: what this row's load really was.
    const load = loadFactor();
    await page.waitForTimeout(500);
    await page.evaluate(() => (window as any).__benchTypingLoad.stop());
    const after = await metrics();
    if (PROFILE && cdp) {
      const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
      printProfile(`${mode.id} ${length} rows`, profile);
    }
    const { renders, typing, probe } = (await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      const raw = (window as any).__benchTypingLoad;
      return {
        renders: debug.renders(),
        typing: debug.typingStats(),
        probe: { longTasks: raw.longTasks, frames: raw.frames, keys: raw.keys, longTaskSupport: raw.longTaskSupport },
      };
    })) as {
      renders: Record<string, number>;
      typing: Record<string, any>;
      probe: Parameters<typeof summarizeTypingProbe>[0];
    };
    await streaming;
    // Per stream event, nobody typing: the composer's renders while a reply and tool calls stream (loadRun), then
    // while a tool's output ticks and another chat changes (loadTick).
    let composerPerEvent: number | undefined;
    let composerPerTick: number | undefined;
    if (mode.web.focusedStream) {
      const run = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 3, chunk_ms: 16, tool_every: 10, scroll_speed: 0 }),
      )) as { renders: Record<string, number>; deltas: number; tools: number };
      composerPerEvent = Math.round(((run.renders.composer ?? 0) / Math.max(1, run.deltas + run.tools)) * 1000) / 1000;
      const tick = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 100, scroll_speed: 0 }),
      )) as { renders: Record<string, number>; ticks?: number; sidebar?: number };
      composerPerTick =
        Math.round(((tick.renders.composer ?? 0) / Math.max(1, (tick.ticks ?? 0) + (tick.sidebar ?? 0))) * 1000) / 1000;
    }
    const per = (value: number) => Math.round((value / KEYS) * 100) / 100;
    const sum = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const delta = (name: string) => (after[name] ?? 0) - (before[name] ?? 0);
    return {
      mode: mode.id,
      engine,
      rows,
      keys: typing.keys,
      to_frame_p50: typing.to_frame?.p50_ms,
      to_frame_p95: typing.to_frame?.p95_ms,
      to_frame_p99: typing.to_frame?.p99_ms,
      to_frame_max: typing.to_frame?.max_ms,
      ...summarizeTypingProbe(probe),
      load,
      pane: per(renders.pane ?? 0),
      transcript: per(renders.transcript ?? 0),
      composer: per(renders.composer ?? 0),
      rowRenders: per(sum("row:") + sum("content:")),
      rowFrames: per(sum("frame:")),
      layouts: cdp ? per(delta("LayoutCount")) : undefined,
      styles: cdp ? per(delta("RecalcStyleCount")) : undefined,
      script_ms: cdp ? per(delta("ScriptDuration") * 1000) : undefined,
      layout_ms: cdp ? per(delta("LayoutDuration") * 1000) : undefined,
      style_ms: cdp ? per(delta("RecalcStyleDuration") * 1000) : undefined,
      task_ms: cdp ? per(delta("TaskDuration") * 1000) : undefined,
      to_listener_p95: typing.to_listener?.p95_ms,
      to_work_p95: typing.to_work?.p95_ms,
      composer_per_stream_event: composerPerEvent,
      composer_per_tick_event: composerPerTick,
      other_chats: mode.web.otherChats,
      cpu_burners: burners?.count ?? 0,
      missing: (mode.webMissing ?? []).join("; "),
      nativePosts: JSON.stringify(typing.native_posts ?? {}),
      busiest: Object.entries(renders)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 8)
        .map(([name, value]) => `${name}=${value}`)
        .join(" "),
    };
  } finally {
    burners?.stop();
    await others?.close();
    await page.close();
  }
}

try {
  const table: Row[] = [];
  for (const engine of ENGINES) {
    const browser = await (engine === "webkit" ? webkit : chromium).launch({ headless: true });
    releases.push(() => browser.close());
    for (const mode of MODES)
      for (const length of rowsFor(mode, LENGTHS)) {
        try {
          table.push(await measure(browser, engine, mode, length));
        } catch (error) {
          console.log(`${engine} ${mode.id} ${length} rows: failed: ${String(error)}`);
          table.push({ mode: mode.id, engine, rows: length, failed: String(error) });
        }
      }
  }
  console.table(table.map(({ busiest: _busiest, nativePosts: _posts, missing: _missing, ...row }) => row));
  for (const row of table) {
    if (row.missing) console.log(`${String(row.mode)}: not expressed by a page harness: ${String(row.missing)}`);
    if (row.busiest)
      console.log(
        `${String(row.engine)} ${String(row.mode)} ${String(row.rows)} rows: ${String(row.busiest)}; native posts ${String(row.nativePosts)}`,
      );
  }
  console.log(`COMPOSER-TYPING ${JSON.stringify(table)}`);
  const gate = GATE_P95 ?? (argv.includes("--gate") ? GATE_P95_MS : undefined);
  if (gate !== undefined) {
    const over = table.filter((row) => typeof row.to_frame_p95 === "number" && (row.to_frame_p95 as number) > gate);
    for (const row of over)
      console.log(
        `GATE ${String(row.engine)} ${String(row.mode)}: key to frame p95 ${String(row.to_frame_p95)} ms over ${gate} ms`,
      );
    if (over.length) process.exitCode = 1;
  }
} finally {
  for (const release of releases.reverse()) await release();
}
