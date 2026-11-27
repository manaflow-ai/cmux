// l10n-allow-file: benchmark output, not shipped UI.
// What one keystroke in the agent chat's composer costs, at transcript lengths of 60, 1,500 and 6,000 rows (CMUX-571,
// Leo: "improve performance (chat, everything related)"; Leo, 2026-11-12: long chats must have "no perceivable
// difference"). A key should render the composer and nothing that does not read its text: not the pane root, not the
// transcript, not a row, and its cost should not grow with the transcript.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), built as it ships (the server
// setup below). Each length is a light chat
// (`cmuxAcpmuxDebug.loadSeed(turns, { light: true })`), then `--keys` letters typed into the prompt with real key
// events (Playwright's keyboard, `--gap` ms apart, about a fast typist's pace). Per key:
//   renders   `acpmuxPerf.renders`: the pane root (AcpmuxPane), the transcript, the composer, every row and row frame
//   layout    the page's layouts and style recalcs (CDP Performance.getMetrics LayoutCount, RecalcStyleCount)
//   script    main-thread script, layout and style time (ScriptDuration, LayoutDuration, RecalcStyleDuration), ms
//   to_frame  the page's own typingStats (keydown to the next frame, p50 / p95 / max), as the Mac bench reads it
//   long_tasks  main-thread tasks of 50 ms or more while the keys are typed (PerformanceObserver longtask), and
//             longest_task_ms the longest (0 when none)
//   stream    with --modes idle,stream: the same keys while the chat streams a reply (60 deltas/s, a tool call every
//             30), and, with no typing, the composer's renders per streamed event (reply text and tool calls, then a
//             tool's output ticking while another chat changes: debug loadRun and loadTick). A stream event the
//             composer does not show should render it 0 times. The same run reports the transcript's and its rows'
//             renders per streamed event (transcript_per_stream_event, rows_per_stream_event): the per-key columns
//             divide the window's renders by the key count, so only these separate the stream's own draw cost from
//             anything a keypress causes. One render per event is a coalesced draw; more is a frame it will redraw.
//             STREAM-SPANS lines carry that run's spans (perf.ts `span`), which name the work each streamed frame
//             spends its time in (flush.scroll, flush.drawn, vt.body, row.renders) where a render count cannot.
//   reply     with --modes reply: the same keys while one long reply streams, for each --reply-words length (default
//             2000,20000 words): its first words arrive at once and reveal, then the stream appends to it with no tool
//             call. frame_p50 / frame_p95 (every mode) are each display frame's work while the keys are typed, rAF to
//             after the page rendered it: in reply mode, what one reveal frame costs against the reply's length.
// Every length and mode is a fresh browser process and page. With `--arms A=DIR,B=DIR` it measures two webviews
// trees in one run, interleaved A B B A for `--rounds` rounds (default 6) with a base-against-base noise floor, and
// prints each arm's median and spread (composer-arms.ts).
//   bun bench/composer-typing.bench.ts [--lengths 60,1500,6000] [--keys 60] [--gap 80] [--modes idle,stream,reply] [--reply-words 2000,20000] [--dev] [--profile]
//     [--arms A=.,B=../webviews-b] [--rounds 6] [--no-floor] [--queue 10] [--engine webkit] [--cold] [--draft 20000] [--frames]
// With --frames, a Chromium trace splits each key's keydown-to-paint by what it waited on (keyFrameTrace.ts;
// `KEY-FRAMES` lines): the key's own task, work queued before its frame, the display tick, the frame's callbacks and rendering.
// With --queue N the chat has N prompts waiting in its queue above the composer (ComposerQueue), which a key
// should neither render nor lay out.
// `--engine webkit` types the same keys in Playwright's WebKit, the engine the Mac app ships: the page's own typing
// rows (to_listener, to_work, to_frame) and the render counts only, since the layout, style, script and task columns,
// --profile and --trace read Chromium's DevTools protocol.
/// <reference types="bun" />
import path from "node:path";
import { chromium, webkit } from "./browsers";
import { runComposerLoad } from "./composer-load";
import { composerTypingRows } from "./composerTypingRows";
import { perfRow } from "./perfRow";
import { requireProductionReact, installReactWatch, waitForPageHook, watchPageErrors } from "./support/benchPage";
import type { Page } from "playwright";
import { parseArms, runArms, servePane } from "./composer-arms";
import { reportTrace, traceWindow } from "./styleInvalidationTrace";
import { sourceMapper } from "./sourceMapper";
import { FRAME_CATEGORIES, reportFrames, traceFrames } from "./keyFrameTrace";
let mapUrl: (file: string, line: number, column: number) => string = (file, line) => `${file}:${line + 1}`;

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "60,1500,6000").split(",").map(Number);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
const MODES = (flag("--mode") ?? flag("--modes") ?? "idle").split(",");
// `--engine webkit` (one engine) and `--engines chromium,webkit` (each in turn) name the same thing: without
// --engines the single run takes --engine's, so `--engine webkit` alone types in WebKit and not, as it did, in Chromium.
const ENGINES = (flag("--engines") ?? flag("--engine") ?? "chromium").split(",");
const STREAM = Number(flag("--stream") ?? 60);
const TOOL_LINES = Number(flag("--tool-lines") ?? 2000);
if (
  MODES.some((mode) => !["idle", "stream", "reply", "L0", "L1", "L2", "L3"].includes(mode)) ||
  ENGINES.some((engine) => !["chromium", "webkit"].includes(engine)) ||
  !Number.isInteger(KEYS) ||
  KEYS < 1 ||
  KEYS > 4096 ||
  !Number.isFinite(GAP_MS) ||
  GAP_MS < 1 ||
  KEYS * GAP_MS > 90000 ||
  LENGTHS.some((length) => !Number.isInteger(length) || length < 1)
)
  throw new Error("Invalid benchmark modes, engines, keys, gap or lengths (typing window must be <=90s)");
/// With --modes reply: the reply lengths, in words, that one streaming reply has on screen while the keys are typed.
const REPLY_WORDS = (flag("--reply-words") ?? "2000,20000").split(",").map(Number);
/// How long the long reply's first words get to reveal before the timed stream and the keys start.
const REPLY_SETTLE_MS = 1500;
/// With --profile: a CPU profile over the typed keys, and the functions with the most time per key (inclusive and self).
const PROFILE = argv.includes("--profile");
if (PROFILE && ENGINES.includes("webkit")) throw new Error("--profile reads Chromium's DevTools protocol");
const DEV = argv.includes("--dev");
/// With --trace: a Chromium trace with style invalidation tracking over the typed keys and, in stream mode, over a 2 s
/// stream with no typing; it prints elements restyled per key and per token and what restyled them
/// (styleInvalidationTrace.ts; `STYLE-TRACE ... SUMMARY` lines).
const TRACE = argv.includes("--trace");
/// With --frames: a Chromium trace over the typed keys read per key from keydown to paint: the key's own task, the
/// work between it and its frame, the wait for the display tick, the frame callbacks ahead of the key's, that frame's
/// rendering, and a breakdown of every main-thread task in the window (keyFrameTrace.ts; `KEY-FRAMES` lines).
const FRAMES = argv.includes("--frames");
const webviews = path.resolve(import.meta.dir, "..");
const ARMS = parseArms(flag("--arms"), webviews);
const ROUNDS = Number(flag("--rounds") ?? 6);
/// --repeat N: each case runs N times and reports the valid attempt with the median keydown-to-paint p99, so one burst
/// from a job sharing the host (the nightly's cmux-linux pool VMs run several runner slots) is not the reading. WebKit
/// L0 read p99 155 ms on the 14:17Z 2026-11-26 nightly while its p95 was 39 ms, its handler work 10 ms and its driver
/// on time; on a quiet host the same row reads 18-29 ms. Every attempt's p99 and validity stay in the table.
const REPEAT = Number(flag("--repeat") ?? 1);
if (!Number.isInteger(REPEAT) || REPEAT < 1) throw new Error(`--repeat must be a whole number from 1, not ${REPEAT}`);
const FLOOR = !argv.includes("--no-floor");
const COLD = argv.includes("--cold");
const ENGINE = flag("--engine") ?? (ENGINES.length === 1 ? ENGINES[0]! : "chromium");
if (ENGINE !== "chromium" && ENGINE !== "webkit") throw new Error(`--engine must be chromium or webkit, not ${ENGINE}`);
if (ENGINES.includes("webkit") && (PROFILE || TRACE || FRAMES))
  throw new Error("--profile and --trace read Chromium's DevTools protocol");
/// Prompts waiting in the chat's queue while the keys are typed (0: none).
const QUEUED = Number(flag("--queue") ?? 0);
/// With --draft N the prompt already holds N characters of text (lines of about 80) when the measured keys are typed
/// at its end: a key into a long draft should cost what a key into an empty one does.
const DRAFT = Number(flag("--draft") ?? 0);
if (!Number.isInteger(DRAFT) || DRAFT < 0)
  throw new Error(`--draft must be a whole number of characters, not ${DRAFT}`);
// WebKit runs and the L0-L3 load modes go through runComposerLoad, which never fills the draft: refuse them
// rather than measure an empty prompt and call it a long draft.
if (DRAFT > 0 && (ENGINE === "webkit" || ENGINES.includes("webkit") || MODES.some((mode) => mode.startsWith("L"))))
  throw new Error("--draft runs in Chromium's idle and stream modes only; WebKit and L0-L3 never fill the draft");
/// What an A/B of arms summarizes: key to frame, key to listener and the long tasks.
const ARM_METRICS = [
  "frame_p50",
  "frame_p95",
  "to_frame_p50",
  "to_frame_p95",
  "to_frame_max",
  "to_listener_p95",
  "to_paint_p95",
  "to_paint_p99",
  "to_work_p50",
  "to_work_p95",
  "script_ms",
  "task_ms",
  "longest_task_ms",
  "long_tasks",
] as const;
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const METRICS = [
  "LayoutCount",
  "RecalcStyleCount",
  "ScriptDuration",
  "LayoutDuration",
  "RecalcStyleDuration",
  "TaskDuration",
] as const;

async function openChat(page: Page, port: number, turns: number) {
  // Before the page's own code (bench/support/benchPage.ts installReactWatch).
  await installReactWatch(page);
  const errors = watchPageErrors(page);
  const response = await page.goto(`http://127.0.0.1:${port}/?mock`);
  const status = response?.status();
  // A 404 body loads as a page, and the wait below would then be 60 s of nothing (composer-load.ts).
  if (status !== undefined && status >= 400)
    throw new Error(`openChat: http://127.0.0.1:${port}/?mock answered ${status}; the pane page is not there`);
  // `servePane` builds the pane unless `--dev`; the check reads which React the page loaded
  // (bench/support/benchPage.ts).
  await waitForPageHook(page, "cmuxAcpmuxDebug", { timeout: 60_000, errors });
  // After the pane is up: react-dom rides a lazy chunk the page fetches when it mounts, so asking
  // right after `goto` read as "no react-dom on this page" (bench/support/benchPage.ts).
  await requireProductionReact(page, { dev: DEV });
  const seeded = (await page.evaluate(
    ([count, queued]) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true, queued }),
    [turns, QUEUED] as const,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
  if (QUEUED > 0) await page.locator(".acpmux-composer-queue .acpmux-queued").first().waitFor({ timeout: 20_000 });
  return seeded.rows as number;
}

/// Init script (self-contained): every long task from page load, for the window the keys are typed in.
function longTaskProbe() {
  const w = window as unknown as { __longTasks?: { at: number; ms: number }[] };
  if (w.__longTasks) return;
  const tasks: { at: number; ms: number }[] = [];
  w.__longTasks = tasks;
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) tasks.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without long tasks reads 0.
  }
}

type CpuProfile = {
  nodes: {
    id: number;
    callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number };
    children?: number[];
  }[];
  samples: number[];
  timeDeltas: number[];
};

/// Per key, ms: each function's inclusive time (once per sample however deep it recurses) and self time.
function printProfile(length: number, profile: CpuProfile) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  // Each node's name once: the source line the build's map gives (a bundle line says nothing once it is rebuilt).
  const names = new Map<number, string>();
  const name = (id: number) => {
    let known = names.get(id);
    if (known === undefined) {
      const frame = byId.get(id)!.callFrame;
      const file = frame.url.split("/").pop()?.split("?")[0] ?? "";
      known = `${frame.functionName || "(anon)"} ${file ? mapUrl(file, frame.lineNumber, frame.columnNumber) : ":0"}`;
      names.set(id, known);
    }
    return known;
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
  console.log(`PROFILE ${length} rows, inclusive:\n${top(inclusive, 150)}`);
  console.log(`PROFILE ${length} rows, self:\n${top(self, 60)}`);
}

// The pane as it ships (a vite build: production React, the React Compiler pass), served as files; --dev serves the
// dev server's pane instead (development React, several times the script time per render). With --profile the build
// is unminified, so the profile names functions.
const releases: (() => unknown)[] = [];
// --trace and --profile build unminified with source maps, so the trace and the profile name source lines (a second
// arm's build maps over the first's: profile one tree at a time).
const serveOptions = {
  dev: DEV,
  unminified: PROFILE || TRACE || FRAMES,
  sourcemap: PROFILE || TRACE || FRAMES,
  built: PROFILE || TRACE || FRAMES ? (out: string) => void (mapUrl = sourceMapper(out)) : undefined,
};

/// One length in one mode on the pane served at `port`: a fresh browser process and page, the keys typed, its row.
/// Init script (self-contained): the work of every display frame from `__frameWork.start()` to `stop()`, rAF time to
/// after the page rendered it (a posted message runs after the rendering update), as loadDebug.ts `loadRun` reads it.
function frameWorkProbe() {
  const w = window as unknown as { __frameWork?: { start(): void; stop(): number[] } };
  if (w.__frameWork) return;
  let on = false;
  let work: number[] = [];
  const tick = (now: number) => {
    if (!on) return;
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      work.push(performance.now() - now);
    };
    channel.port2.postMessage(0);
    requestAnimationFrame(tick);
  };
  w.__frameWork = {
    start() {
      work = [];
      on = true;
      requestAnimationFrame(tick);
    },
    stop() {
      on = false;
      return work;
    },
  };
}

const pct = (values: number[], at: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length
    ? Math.round(sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * at))]! * 100) / 100
    : 0;
};

async function measure(
  port: number,
  length: number,
  mode: string,
  engine: "chromium" | "webkit" = ENGINE as "chromium" | "webkit",
  replyWords = 0,
): Promise<Record<string, unknown>> {
  const browser = await (engine === "webkit" ? webkit : chromium).launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    if (mode.startsWith("L") || engine === "webkit") {
      const canonical = mode === "idle" ? "L0" : mode === "stream" ? "L1" : mode;
      // One renderer runs the focused page and L2's documents, so its profile is what every key waits behind.
      const cdp = PROFILE && engine === "chromium" ? await page.context().newCDPSession(page) : undefined;
      const profiled = cdp && {
        start: async () => {
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
          await cdp.send("Profiler.start");
        },
        stop: async () => {
          const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
          printProfile(length, profile);
        },
      };
      // With --frames, the same per-key split as the legacy modes (keyFrameTrace.ts), over the typed keys under load.
      const framed = FRAMES &&
        engine === "chromium" && {
          start: () => browser.startTracing(page, { categories: FRAME_CATEGORIES }),
          stop: async () => {
            const events = (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: any[] }).traceEvents;
            reportFrames(`${canonical}-typing ${length}rows`, events, mapUrl);
          },
        };
      const typing = profiled || framed;
      try {
        return {
          engine,
          ...(await runComposerLoad(page, {
            port,
            mode: canonical,
            length,
            keys: KEYS,
            gap: GAP_MS,
            stream: STREAM,
            toolLines: TOOL_LINES,
            typing: typing || undefined,
          })),
        };
      } finally {
        await page.close();
      }
    }
    await page.addInitScript(longTaskProbe);
    await page.addInitScript(frameWorkProbe);
    const rows = await openChat(page, port, Math.max(1, Math.round(length / 3)));
    // WebKit returned above (runComposerLoad): this run is Chromium's, with its DevTools session.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const metrics = async (): Promise<Record<string, number>> => {
      const { metrics: list } = (await cdp.send("Performance.getMetrics")) as {
        metrics: { name: string; value: number }[];
      };
      return Object.fromEntries(
        list.filter((m) => (METRICS as readonly string[]).includes(m.name)).map((m) => [m.name, m.value]),
      );
    };
    await page.locator(PROMPT).first().click();
    // Warm-up: the first keys load the composer's lazy parts (emoji data, the mention index). With --cold the
    // measured keys are the chat's first, as the perf cron's chat-anim part types them (agent-engine-bench.py).
    if (!COLD) {
      for (const key of "warm") await page.keyboard.press(key);
      await page.waitForTimeout(500);
      // Three of the four go: one letter stays, so the measured keys type into a prompt that already has
      // words. The empty-to-typed step is a real change of the UI (Send takes Stop's slot, a suggestion goes)
      // and renders once by design (composer/promptText.ts PromptFacts `blank`/`empty`); it is not what a key
      // costs. Clearing the prompt here put that one render on the first measured key, hiding the per-key cost
      // behind 1/60 of a transition (#45279, carried forward).
      for (let i = 0; i < 3; i += 1) await page.keyboard.press("Backspace");
    }
    if (DRAFT > 0) {
      const line = "the quick brown fox jumps over the lazy dog and keeps on running past the old fence";
      const lines: string[] = [];
      for (let size = 0; size < DRAFT; size += line.length + 1) lines.push(line);
      await page.keyboard.insertText(lines.join("\n").slice(0, DRAFT));
      await page.waitForTimeout(1000);
      const held = await page
        .locator(PROMPT)
        .first()
        .evaluate((field) => (field.textContent ?? "").length);
      // A draft the field did not take measures an empty prompt: a run that says it typed into N characters must have.
      if (held < DRAFT * 0.9) throw new Error(`--draft ${DRAFT}: the prompt holds ${held} characters`);
      console.log(`DRAFT ${DRAFT} characters asked, ${held} in the prompt`);
    }
    await page.waitForTimeout(500);
    await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      debug.resetTyping();
      debug.renders();
    });
    if (PROFILE) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    // Stream mode: a reply streams in for the whole typing run (no scrolling), a tool call every 30 deltas.
    // Reply mode: one reply of `replyWords` words is on screen, and the same stream appends to it with no tool call
    // (a tool call would end the reply's row and start a short one), so each frame's cost reads against its length.
    const streaming =
      mode === "stream"
        ? page.evaluate(
            (seconds: number) =>
              (window as any).cmuxAcpmuxDebug.loadRun({ seconds, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
            (KEYS * (GAP_MS + 20)) / 1000 + 1,
          )
        : mode === "reply"
          ? page.evaluate(
              ([seconds, words, settle]) =>
                (window as any).cmuxAcpmuxDebug.loadRun({
                  seconds,
                  chunk_ms: 16,
                  tool_every: 0,
                  scroll_speed: 0,
                  reply_words: words,
                  reply_settle_ms: settle,
                }),
              [(KEYS * (GAP_MS + 20)) / 1000 + 1, replyWords, REPLY_SETTLE_MS] as const,
            )
          : Promise.resolve(undefined);
    if (mode !== "idle") {
      await page.waitForTimeout(mode === "reply" ? REPLY_SETTLE_MS + 300 : 300);
      await page.evaluate(() => {
        const debug = (window as any).cmuxAcpmuxDebug;
        debug.resetTyping();
        debug.renders();
      });
    }
    const before = await metrics();
    const since = await page.evaluate(() => performance.now());
    const letters = "abcdefghijklmnopqrstuvwxyz";
    const typeKeys = async () => {
      for (let i = 0; i < KEYS; i += 1) {
        await page.keyboard.press(letters[i % letters.length]!);
        await page.waitForTimeout(GAP_MS);
      }
    };
    await page.evaluate(() => (window as any).__frameWork.start());
    const typedAt = performance.now();
    let frameEvents: Awaited<ReturnType<typeof traceFrames>> | undefined;
    const typedEvents = TRACE
      ? await traceWindow(browser, page, typeKeys)
      : FRAMES
        ? ((frameEvents = await traceFrames(browser, page, typeKeys)), undefined)
        : (await typeKeys(), undefined);
    const typedMs = performance.now() - typedAt;
    const frameWork = (await page.evaluate(() => (window as any).__frameWork.stop())) as number[];
    await page.waitForTimeout(500);
    const after = await metrics();
    const until = await page.evaluate(() => performance.now());
    const long = (
      (await page.evaluate(
        () => (window as unknown as { __longTasks?: { at: number; ms: number }[] }).__longTasks ?? [],
      )) as { at: number; ms: number }[]
    ).filter((task) => task.at + task.ms >= since && task.at <= until);
    if (PROFILE) {
      const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
      printProfile(length, profile);
    }
    const { renders, typing } = (await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      return { renders: debug.renders(), typing: debug.typingStats() };
    })) as { renders: Record<string, number>; typing: Record<string, any> };
    await streaming;
    if (typedEvents) {
      await cdp.send("DOM.getDocument", { depth: 0 });
      await reportTrace(`${mode}-typing ${rows}rows`, typedEvents, { keys: KEYS }, mapUrl, cdp);
      console.log(
        `STYLE-TRACE ${mode}-typing ${rows}rows WINDOW ${JSON.stringify({ keys: KEYS, window_ms: Math.round(typedMs) })}`,
      );
    }
    if (frameEvents) reportFrames(`${mode}-typing ${rows}rows`, frameEvents, mapUrl);
    if (TRACE && mode === "stream") {
      let run: Record<string, any> = {};
      const events = await traceWindow(browser, page, async () => {
        run = (await page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 2, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
        )) as Record<string, any>;
      });
      const tokens = Number(run.deltas ?? 0) + Number(run.tools ?? 0);
      console.log(
        `STYLE-TRACE stream-only ${rows}rows RUN ${JSON.stringify({ deltas: run.deltas, tools: run.tools, frames: run.frames, rows: run.rows })}`,
      );
      await cdp.send("DOM.getDocument", { depth: 0 });
      await reportTrace(`stream-only ${rows}rows`, events, { tokens }, mapUrl, cdp);
    }
    // Per stream event, nobody typing: the composer's renders while a reply and tool calls stream
    // (loadRun), then while a tool's output ticks and another chat changes (loadTick).
    let composerPerEvent: number | undefined;
    let composerPerTick: number | undefined;
    /// The transcript's and its rows' renders per streamed event with nobody typing: the stream's own
    /// draw cost, which the per-key columns above divide by the key count and so cannot separate. One
    /// render per event is a coalesced draw; more than one is the stream drawing a frame it will redraw.
    let transcriptPerEvent: number | undefined;
    let rowsPerEvent: number | undefined;
    if (mode === "stream") {
      const run = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 3, chunk_ms: 16, tool_every: 10, scroll_speed: 0 }),
      )) as {
        renders: Record<string, number>;
        deltas: number;
        tools: number;
        spans?: Record<string, { p50_ms?: number; p95_ms?: number; max_ms?: number }>;
      };
      const runEvents = Math.max(1, run.deltas + run.tools);
      // Which work each streamed frame spends its time in, with nobody typing: the spans name the
      // update that draws the transcript again (perf.ts `span`), which a render count cannot.
      console.log(
        `STREAM-SPANS ${rows}rows ${JSON.stringify({ events: runEvents, spans: run.spans, renders: run.renders })}`,
      );
      composerPerEvent = Math.round(((run.renders.composer ?? 0) / runEvents) * 1000) / 1000;
      transcriptPerEvent = Math.round(((run.renders.transcript ?? 0) / runEvents) * 1000) / 1000;
      const runRows = Object.entries(run.renders)
        .filter(([name]) => name.startsWith("row:") || name.startsWith("content:"))
        .reduce((total, [, value]) => total + value, 0);
      rowsPerEvent = Math.round((runRows / runEvents) * 1000) / 1000;
      const tick = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 100, scroll_speed: 0 }),
      )) as { renders: Record<string, number>; ticks?: number; sidebar?: number };
      composerPerTick =
        Math.round(((tick.renders.composer ?? 0) / Math.max(1, (tick.ticks ?? 0) + (tick.sidebar ?? 0))) * 1000) / 1000;
    }
    await page.close();
    const per = (value: number) => Math.round((value / KEYS) * 100) / 100;
    const sum = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const delta = (name: string) => (after[name] ?? 0) - (before[name] ?? 0);
    return {
      engine,
      mode,
      rows,
      ...(mode === "reply" ? { reply_words: replyWords } : {}),
      frame_p50: pct(frameWork, 0.5),
      frame_p95: pct(frameWork, 0.95),
      keys: typing.keys,
      pane: per(renders.pane ?? 0),
      transcript: per(renders.transcript ?? 0),
      composer: per(renders.composer ?? 0),
      queue: per(renders["composer:queue"] ?? 0),
      queued: QUEUED,
      draft: DRAFT,
      rowRenders: per(sum("row:") + sum("content:")),
      rowFrames: per(sum("frame:")),
      layouts: per(delta("LayoutCount")),
      styles: per(delta("RecalcStyleCount")),
      script_ms: per(delta("ScriptDuration") * 1000),
      layout_ms: per(delta("LayoutDuration") * 1000),
      style_ms: per(delta("RecalcStyleDuration") * 1000),
      task_ms: per(delta("TaskDuration") * 1000),
      to_listener_p95: typing.to_listener?.p95_ms,
      to_work_p50: typing.to_work?.p50_ms,
      to_work_p95: typing.to_work?.p95_ms,
      to_frame_p50: typing.to_frame?.p50_ms,
      to_frame_p95: typing.to_frame?.p95_ms,
      to_frame_max: typing.to_frame?.max_ms,
      // Key to its painted frame (perf.ts's post-paint mark, what the perf watch's composer.key_paint judges), the
      // frames the keys dropped against the measured frame interval, and the longest prompt a key landed in.
      to_paint_p50: typing.to_paint?.p50_ms,
      to_paint_p95: typing.to_paint?.p95_ms,
      to_paint_p99: typing.to_paint?.p99_ms,
      dropped_frames: typing.dropped_frames,
      frame_interval_ms: typing.frame_interval_ms,
      prompt_chars: typing.max_chars,
      longest_task_ms: Math.round(Math.max(0, ...long.map((task) => task.ms)) * 10) / 10,
      long_tasks: long.length,
      composer_per_stream_event: composerPerEvent,
      composer_per_tick_event: composerPerTick,
      transcript_per_stream_event: transcriptPerEvent,
      rows_per_stream_event: rowsPerEvent,
      nativePosts: JSON.stringify(typing.native_posts ?? {}),
      busiest: Object.entries(renders)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 8)
        .map(([name, value]) => `${name}=${value}`)
        .join(" "),
    };
  } finally {
    await browser.close();
  }
}

/// One case REPEAT times: the valid attempt with the (lower) median to_paint_p99, else the first attempt.
async function measureRepeated(
  port: number,
  length: number,
  mode: string,
  engine: "chromium" | "webkit",
  replyWords: number,
): Promise<Record<string, unknown>> {
  const attempts: Record<string, unknown>[] = [];
  for (let attempt = 0; attempt < REPEAT; attempt++)
    attempts.push(await measure(port, length, mode, engine, replyWords));
  if (REPEAT === 1) return attempts[0]!;
  const p99 = (row: Record<string, unknown>) => row.to_paint_p99;
  const valid = attempts
    .filter((row) => row.valid === true && typeof p99(row) === "number" && Number.isFinite(p99(row)))
    .sort((a, b) => (p99(a) as number) - (p99(b) as number));
  const chosen = valid.length ? valid[Math.floor((valid.length - 1) / 2)]! : attempts[0]!;
  return {
    ...chosen,
    attempts: REPEAT,
    attempts_valid: valid.length,
    attempt_valid: attempts.map((row) => row.valid ?? null),
    attempt_to_paint_p95: attempts.map((row) => row.to_paint_p95 ?? null),
    attempt_to_paint_p99: attempts.map((row) => p99(row) ?? null),
  };
}

try {
  const cases = LENGTHS.flatMap((length) =>
    MODES.flatMap((mode) =>
      mode === "reply" ? REPLY_WORDS.map((words) => ({ length, mode, words })) : [{ length, mode, words: 0 }],
    ),
  );
  if (ARMS && ENGINES.length > 1)
    throw new Error("--arms measures one engine: pass --engine chromium or --engine webkit, not a list");
  if (ARMS) {
    // Two source trees in one run: each built and served once, then every case interleaved (composer-arms.ts).
    const ports = new Map<string, number>();
    for (const arm of ARMS) ports.set(arm.name, await servePane(arm.dir, serveOptions, releases));
    const runs: Record<string, unknown>[] = [];
    for (const { length, mode, words } of cases)
      runs.push(
        ...(await runArms({
          arms: ARMS,
          rounds: ROUNDS,
          floor: FLOOR,
          label: `${mode} ${length} rows${words ? ` ${words} words` : ""}`,
          metrics: ARM_METRICS,
          ports,
          run: (port) => measure(port, length, mode, ENGINES[0] as "chromium" | "webkit", words),
        })),
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(runs)}`);
  } else {
    const port = await servePane(webviews, serveOptions, releases);
    const table: Record<string, unknown>[] = [];
    for (const engine of ENGINES)
      for (const { length, mode, words } of cases)
        table.push(await measureRepeated(port, length, mode, engine as "chromium" | "webkit", words));
    console.table(table.map(({ busiest: _, nativePosts: __, ...row }) => row));
    for (const row of table)
      console.log(
        `${String(row.mode)} ${String(row.rows)} rows: ${String(row.busiest)}; native posts ${String(row.nativePosts)}`,
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(table)}`);
    // Load modes only: the rows web-ui-suite.ts collects for perf-cron.py (web-ui-typing) and `cmux-bench typing`.
    for (const row of composerTypingRows(table)) perfRow(row);
  }
} finally {
  for (const release of releases.reverse()) await release();
}
