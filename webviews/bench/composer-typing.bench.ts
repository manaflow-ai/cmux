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
//             composer does not show should render it 0 times.
// Every length and mode is a fresh browser process and page. With `--arms A=DIR,B=DIR` it measures two webviews
// trees in one run, interleaved A B B A for `--rounds` rounds (default 6) with a base-against-base noise floor, and
// prints each arm's median and spread (composer-arms.ts).
//   bun bench/composer-typing.bench.ts [--lengths 60,1500,6000] [--keys 60] [--gap 80] [--modes idle,stream] [--dev] [--profile]
//     [--arms A=.,B=../webviews-b] [--rounds 6] [--no-floor]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import { requireProductionReact, installReactWatch } from "./support/benchPage";
import type { Page } from "playwright";
import { parseArms, runArms, servePane } from "./composer-arms";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "60,1500,6000").split(",").map(Number);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
const MODES = (flag("--modes") ?? "idle").split(",") as ("idle" | "stream")[];
/// With --profile: a CPU profile over the typed keys, and the functions with the most time per key (inclusive and self).
const PROFILE = argv.includes("--profile");
const DEV = argv.includes("--dev");
const webviews = path.resolve(import.meta.dir, "..");
const ARMS = parseArms(flag("--arms"), webviews);
const ROUNDS = Number(flag("--rounds") ?? 6);
const FLOOR = !argv.includes("--no-floor");
/// What an A/B of arms summarizes: key to frame, key to listener and the long tasks.
const ARM_METRICS = [
  "to_frame_p50",
  "to_frame_p95",
  "to_frame_max",
  "to_listener_p95",
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
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  // `servePane` builds the pane unless `--dev`; the check reads which React the page loaded
  // (bench/support/benchPage.ts).
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  // After the pane is up: react-dom rides a lazy chunk the page fetches when it mounts, so asking
  // right after `goto` read as "no react-dom on this page" (bench/support/benchPage.ts).
  await requireProductionReact(page, { dev: DEV });
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
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
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples: number[];
  timeDeltas: number[];
};

/// Per key, ms: each function's inclusive time (once per sample however deep it recurses) and self time.
function printProfile(length: number, profile: CpuProfile) {
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
  console.log(`PROFILE ${length} rows, inclusive:\n${top(inclusive, 90)}`);
  console.log(`PROFILE ${length} rows, self:\n${top(self, 40)}`);
}

// The pane as it ships (a vite build: production React, the React Compiler pass), served as files; --dev serves the
// dev server's pane instead (development React, several times the script time per render). With --profile the build
// is unminified, so the profile names functions.
const releases: (() => unknown)[] = [];
const serveOptions = { dev: DEV, unminified: PROFILE };

/// One length in one mode on the pane served at `port`: a fresh browser process and page, the keys typed, its row.
async function measure(port: number, length: number, mode: "idle" | "stream"): Promise<Record<string, unknown>> {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.addInitScript(longTaskProbe);
    const rows = await openChat(page, port, Math.max(1, Math.round(length / 3)));
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const metrics = async () => {
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
    if (PROFILE) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    // Stream mode: a reply streams in for the whole typing run (no scrolling), a tool call every 30 deltas.
    const streaming =
      mode === "stream"
        ? page.evaluate(
            (seconds) =>
              (window as any).cmuxAcpmuxDebug.loadRun({ seconds, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
            (KEYS * (GAP_MS + 20)) / 1000 + 1,
          )
        : Promise.resolve(undefined);
    if (mode === "stream") {
      await page.waitForTimeout(300);
      await page.evaluate(() => {
        const debug = (window as any).cmuxAcpmuxDebug;
        debug.resetTyping();
        debug.renders();
      });
    }
    const before = await metrics();
    const since = await page.evaluate(() => performance.now());
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (let i = 0; i < KEYS; i += 1) {
      await page.keyboard.press(letters[i % letters.length]!);
      await page.waitForTimeout(GAP_MS);
    }
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
    // Per stream event, nobody typing: the composer's renders while a reply and tool calls stream
    // (loadRun), then while a tool's output ticks and another chat changes (loadTick).
    let composerPerEvent: number | undefined;
    let composerPerTick: number | undefined;
    if (mode === "stream") {
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
    await page.close();
    const per = (value: number) => Math.round((value / KEYS) * 100) / 100;
    const sum = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const delta = (name: string) => (after[name] ?? 0) - (before[name] ?? 0);
    return {
      mode,
      rows,
      keys: typing.keys,
      pane: per(renders.pane ?? 0),
      transcript: per(renders.transcript ?? 0),
      composer: per(renders.composer ?? 0),
      rowRenders: per(sum("row:") + sum("content:")),
      rowFrames: per(sum("frame:")),
      layouts: per(delta("LayoutCount")),
      styles: per(delta("RecalcStyleCount")),
      script_ms: per(delta("ScriptDuration") * 1000),
      layout_ms: per(delta("LayoutDuration") * 1000),
      style_ms: per(delta("RecalcStyleDuration") * 1000),
      task_ms: per(delta("TaskDuration") * 1000),
      to_listener_p95: typing.to_listener?.p95_ms,
      to_work_p95: typing.to_work?.p95_ms,
      to_frame_p50: typing.to_frame?.p50_ms,
      to_frame_p95: typing.to_frame?.p95_ms,
      to_frame_max: typing.to_frame?.max_ms,
      longest_task_ms: Math.round(Math.max(0, ...long.map((task) => task.ms)) * 10) / 10,
      long_tasks: long.length,
      composer_per_stream_event: composerPerEvent,
      composer_per_tick_event: composerPerTick,
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

try {
  const cases = LENGTHS.flatMap((length) => MODES.map((mode) => ({ length, mode })));
  if (ARMS) {
    // Two source trees in one run: each built and served once, then every case interleaved (composer-arms.ts).
    const ports = new Map<string, number>();
    for (const arm of ARMS) ports.set(arm.name, await servePane(arm.dir, serveOptions, releases));
    const runs: Record<string, unknown>[] = [];
    for (const { length, mode } of cases)
      runs.push(
        ...(await runArms({
          arms: ARMS,
          rounds: ROUNDS,
          floor: FLOOR,
          label: `${mode} ${length} rows`,
          metrics: ARM_METRICS,
          ports,
          run: (port) => measure(port, length, mode),
        })),
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(runs)}`);
  } else {
    const port = await servePane(webviews, serveOptions, releases);
    const table: Record<string, unknown>[] = [];
    for (const { length, mode } of cases) table.push(await measure(port, length, mode));
    console.table(table.map(({ busiest: _, nativePosts: __, ...row }) => row));
    for (const row of table)
      console.log(
        `${String(row.mode)} ${String(row.rows)} rows: ${String(row.busiest)}; native posts ${String(row.nativePosts)}`,
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(table)}`);
  }
} finally {
  for (const release of releases.reverse()) await release();
}
