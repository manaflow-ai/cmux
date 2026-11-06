// l10n-allow-file: benchmark output, not shipped UI.
// The transcript replay harness: recorded and generated acpmux session logs (bench/replayLogs.ts, keyed by seq) played
// into the real pane (a vite build of the pane's dev entry, joined to a stand-in acpmux) at the page's top speed under
// a replay clock: `Date` reads the time of the newest record played, so a session hours long replays in seconds and
// every elapsed label reads what it read live. Timers stay real; nothing waits on wall time between records.
// Each log is played twice, each time in its own page (live only for a log of 8 records or more: a seeded chat of a
// prompt and its reply says nothing live that its open does not):
//   open   `_acpmux/attach` hands the page the whole log; every row box in the view is sampled each painted frame from
//          the first row painted until the view rests. The first frame should be the final frame.
//   live   the page attaches to an empty session and the log arrives record by record as `_acpmux/event`s: up to
//          BATCH records per painted frame, and a measured burst (`bursts`) one record per frame.
// Rows (bench/perfRow.ts; Chromium only: CDP gives the main thread's task time and the JS heap):
//   transcript_replay.open.cls             worst Layout Instability sum, first paint to rest, over every log (0.01)
//   transcript_replay.open.moved_px        worst move of a row in view at first paint, until rest (1 px; a row that
//                                          left the view counts the view's height)
//   transcript_replay.live.cls             worst layout-shift sum while a log streams in (0.01)
//   transcript_replay.live.long_tasks      long tasks (> 50 ms) while bursts play, all logs (0)
//   transcript_replay.long.token_ms        main-thread ms per streamed reply token, p50 over checkpoints, p95 the worst
//                                          (10 ms: a frame's work)
//   transcript_replay.long.token_slope_ms_per_krow   growth of that per 1000 rows already in the transcript, a
//                                          least-squares slope over the checkpoints (0.1: no O(rows) work per token)
//   transcript_replay.long.tool_output_ms  and .tool_output_slope_ms_per_krow: the same for a shell call's streamed
//                                          output update
//   transcript_replay.long.heap_mb         JS heap after GC, the long log open, less the empty pane's (64 MB)
//   transcript_replay.long.idle_ms_per_s   main-thread ms per second once the replay has settled (1 ms/s: no idle CPU)
// A row over its budget prints a `BUDGET MISS` line that says what broke; with --strict the bench then exits 1. The
// suite (web-ui-suite.ts) runs it without --strict: the perf cron's advisory issue is where a regression shows.
// Every sampler stops when its page closes; finally closes the servers, the browser and the build directory.
// PROFILE=1 builds the pane unminified, takes a CPU profile of every burst and prints, per kind, the functions whose self
// time per record grew most from the first checkpoint to the last: where the O(rows) work is.
// --log FILE (repeatable) plays a recorded acpmux log too: JSON lines of SessionEvents or {events: [...]}, seq-keyed.
//   bun bench/transcript-replay.bench.ts [--turns 600] [--only long,recorded,mock] [--log FILE]... [--strict]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow, TARGET_MS, type PerfRow } from "./perfRow";
import { checkSeq, longLog, mockLogs, parseLog, recordedLog, rowsIn, slope, type ReplayLog } from "./replayLogs";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const TURNS = Number(flag("--turns") ?? 600);
const ONLY = (flag("--only") ?? "long,recorded,mock").split(",");
const STRICT = argv.includes("--strict");
const PROFILE = process.env.PROFILE === "1";
const LOG_FILES = argv.flatMap((arg, index) => (argv[index - 1] === "--log" ? [arg] : []));
if (!Number.isInteger(TURNS) || TURNS < 8 || ONLY.some((name) => !["long", "recorded", "mock"].includes(name))) {
  console.error("usage: bun bench/transcript-replay.bench.ts [--turns 600] [--only long,recorded,mock] [--strict]");
  process.exit(2);
}
/// Records a frame takes outside a burst: a daemon's catch-up arrives about this fast.
const BATCH = 25;
/// The budgets, one rule each (header).
const BUDGET = {
  cls: 0.01,
  movedPx: 1,
  longTasks: 0,
  slope: 0.1,
  heapMb: 64,
  idleMsPerS: 1,
} as const;
const webviews = path.resolve(import.meta.dir, "..");

// ---------- the stand-in acpmux ----------
type Play = { log: ReplayLog; served: number; status: string; socket?: { send(data: string): void } };
let play: Play | undefined;
const summary = (p: Play) => ({
  ...p.log.summary,
  status: p.status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: p.log.events.filter((event) => event.kind === "user_message").length,
  updatedAt: p.log.events.at(-1)?.at ?? Date.now(),
});
function answer(method: string): unknown {
  const p = play!;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary(p)] };
    case "_acpmux/attach":
      return { session: summary(p), lastSeq: p.served, events: p.log.events.slice(0, p.served) };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: p.served };
    default:
      return null;
  }
}
const send = (message: unknown) => play?.socket?.send(JSON.stringify(message));
const emit = (event: EventRecord) => send({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
const changed = (p: Play) =>
  send({
    jsonrpc: "2.0",
    method: "_acpmux/session_changed",
    params: { sessionId: p.log.sessionId, session: summary(p), kind: "status", seq: p.served },
  });

// ---------- the page side ----------
/** Init script: the replay clock, layout-shift and long-task buffers. Self-contained (Playwright serializes it). */
function instrument(start: number) {
  const w = window as unknown as {
    __replayAt?: (at: number) => void;
    __shifts: { at: number; value: number; input: boolean; sources: string[] }[];
    __long: { at: number; ms: number }[];
  };
  if (w.__replayAt) return;
  const Real = Date;
  let now = start;
  class ReplayDate extends Real {
    constructor(...args: unknown[]) {
      if (args.length === 0) super(now);
      else super(...(args as [string]));
    }
    static now() {
      return now;
    }
  }
  (window as unknown as { Date: DateConstructor }).Date = ReplayDate as unknown as DateConstructor;
  w.__replayAt = (at) => {
    if (at > now) now = at;
  };
  w.__shifts = [];
  w.__long = [];
  const describe = (node: Node | null | undefined) => {
    if (!(node instanceof Element)) return node ? node.nodeName.toLowerCase() : "?";
    const row = node.closest<HTMLElement>("[data-row-id]")?.dataset.rowId;
    const cls = typeof node.className === "string" ? node.className.split(" ").filter(Boolean)[0] : undefined;
    return `${node.tagName.toLowerCase()}${cls ? `.${cls}` : ""}${row ? ` (row ${row})` : ""}`;
  };
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as {
        startTime: number;
        value: number;
        hadRecentInput: boolean;
        sources?: { node?: Node | null }[];
      }[])
        w.__shifts.push({
          at: entry.startTime,
          value: entry.value,
          input: entry.hadRecentInput,
          sources: (entry.sources ?? []).map((source) => describe(source.node)),
        });
    }).observe({ type: "layout-shift", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without them: the rows that need them read 0, and the box samples still score moves.
  }
}

const paint = (page: Page, frames: number) =>
  page.evaluate(async (count) => {
    for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
  }, frames);
/// Resolves once the transcript's offset and height have held, with nothing animating, for 12 painted frames.
const rest = (page: Page) =>
  page.evaluate(async () => {
    const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll");
    const moving = () =>
      document
        .getAnimations()
        .some(
          (animation) =>
            animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
        );
    let last = "";
    for (let held = 0, frames = 0; held < 12 && frames < 900; frames += 1) {
      await window.cmuxPaintFrame();
      const node = scroller();
      const now = node ? `${node.scrollTop}:${node.scrollHeight}` : "none";
      held = now === last && !moving() ? held + 1 : 0;
      last = now;
    }
  });
const clockTo = (page: Page, at: number) =>
  page.evaluate((at) => (window as unknown as { __replayAt: (at: number) => void }).__replayAt(at), at);

type Sample = { id: string; y: number; height: number };
/// Samples the rows in view each painted frame, from the first frame that shows one.
function sampleRows() {
  const w = window as unknown as { __rowFrames: Sample[][]; __stopRows?: () => void; __firstRowAt?: number };
  w.__rowFrames = [];
  const read = () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!scroller) return;
    const view = scroller.getBoundingClientRect();
    const frame: Sample[] = [];
    for (const row of scroller.querySelectorAll<HTMLElement>("[data-row-id]")) {
      const box = row.getBoundingClientRect();
      if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
      frame.push({ id: row.dataset.rowId!, y: box.y - view.y, height: box.height });
    }
    if (!frame.length && !w.__rowFrames.length) return;
    if (!w.__rowFrames.length) w.__firstRowAt = performance.now();
    w.__rowFrames.push(frame);
  };
  w.__stopRows = window.cmuxAfterPaint(() => {
    read();
  });
}

/// How far any row in view at the first painted frame moved until the last (pure); a row gone counts `viewHeight`.
export function movedPx(frames: Sample[][], viewHeight: number): { px: number; row: string } {
  const first = frames[0] ?? [];
  let px = 0;
  let row = "none";
  for (const start of first)
    for (const frame of frames) {
      const now = frame.find((each) => each.id === start.id);
      const moved = now ? Math.abs(now.y - start.y) : viewHeight;
      if (moved > px) [px, row] = [moved, start.id];
    }
  return { px: Math.round(px * 10) / 10, row };
}

async function metric(cdp: CDPSession, name: string): Promise<number> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((each) => each.name === name)?.value ?? 0;
}
async function heapMb(cdp: CDPSession): Promise<number> {
  await cdp.send("HeapProfiler.collectGarbage");
  const { usedSize } = (await cdp.send("Runtime.getHeapUsage")) as { usedSize: number };
  return usedSize / 2 ** 20;
}

type Ctx = { browser: Browser; url: (log: ReplayLog) => string };
type Shift = { at: number; value: number; input: boolean; sources: string[] };

async function openPage(ctx: Ctx, log: ReplayLog, served: number, status: string, start: number) {
  play = { log, served, status };
  const page = await ctx.browser.newPage({ viewport: { width: 900, height: 700 } });
  await page.addInitScript(instrument, start);
  await installPaintedFrames(page);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable");
  if (PROFILE) await cdp.send("Profiler.enable");
  return { page, cdp };
}

/// The elements that shifted most, by the layout-shift value they took part in, summed (pure).
export function shiftSources(shifts: readonly Shift[], top = 3): string[] {
  const sum = new Map<string, number>();
  for (const shift of shifts)
    for (const source of shift.sources.length ? shift.sources : ["?"])
      sum.set(source, (sum.get(source) ?? 0) + shift.value);
  return [...sum.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, top)
    .map(
      ([source, value]) =>
        `${source} ${value.toFixed(4)} in ${shifts.filter((s) => s.sources.includes(source)).length} shifts`,
    );
}

type Open = { log: string; cls: number; moved: number; movedRow: string; shiftNotes: string[] };
/// The open phase: the whole log handed over on attach; the rows in view from first paint to rest.
async function openRound(ctx: Ctx, log: ReplayLog): Promise<Open> {
  const last = log.events.at(-1)?.at ?? Date.now();
  const status =
    typeof log.summary.status === "string"
      ? log.summary.status
      : log.events.at(-1)?.kind === "turn_result"
        ? "idle"
        : "running";
  const { page } = await openPage(ctx, log, log.events.length, status, last + 1000);
  try {
    await page.addInitScript(sampleRows);
    await page.goto(ctx.url(log));
    await page.locator("[data-row-id]").first().waitFor({ timeout: 60_000 });
    await rest(page);
    await page.waitForTimeout(400);
    await paint(page, 2);
    const result = await page.evaluate(() => {
      const w = window as unknown as {
        __rowFrames: Sample[][];
        __stopRows?: () => void;
        __firstRowAt?: number;
        __shifts: Shift[];
      };
      w.__stopRows?.();
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")?.getBoundingClientRect().height ?? 0;
      return {
        frames: w.__rowFrames,
        view,
        shifts: w.__shifts.filter((shift) => !shift.input && shift.at >= (w.__firstRowAt ?? 0)),
      };
    });
    const moved = movedPx(result.frames, result.view);
    return {
      log: log.name,
      cls: Math.round(result.shifts.reduce((sum, shift) => sum + shift.value, 0) * 1e4) / 1e4,
      moved: moved.px,
      movedRow: moved.row,
      shiftNotes: shiftSources(result.shifts),
    };
  } finally {
    await page.close();
  }
}

type BurstResult = { kind: string; rows: number; msPerRecord: number; selfMs?: Map<string, number> };
type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
  samples: number[];
  timeDeltas: number[];
};
/// Self time per function (ms) in a profile, each divided by `records` (pure).
export function selfTimes(profile: CpuProfile, records: number): Map<string, number> {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.functionName === "(idle)" || frame.functionName === "(program)") return;
    const file = frame.url.split("/").pop() ?? "";
    const key = `${frame.functionName || "(anon)"}${file ? ` ${file}:${frame.lineNumber + 1}` : ""}`;
    self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000 / records);
  });
  return self;
}
/// The functions whose self time per record grew most from `first` to `last` (pure).
export function grew(first: Map<string, number>, last: Map<string, number>, top = 12): [string, number, number][] {
  return [...last.entries()]
    .map(([key, ms]) => [key, first.get(key) ?? 0, ms] as [string, number, number])
    .sort((a, b) => b[2] - b[1] - (a[2] - a[1]))
    .slice(0, top);
}
type Live = {
  log: string;
  cls: number;
  longTasks: number;
  longestTaskMs: number;
  bursts: BurstResult[];
  heapMb: number;
  idleMsPerS: number;
  seconds: number;
  shiftNotes: string[];
};
/// The live phase: an empty session, then every record as a live event at the page's top speed.
async function liveRound(ctx: Ctx, log: ReplayLog, measureIdle: boolean): Promise<Live> {
  const first = log.events[0]?.at ?? Date.now();
  const { page, cdp } = await openPage(ctx, log, 0, "running", first);
  const started = performance.now();
  try {
    await page.goto(ctx.url(log));
    await page.locator(".acpmux-scroll").waitFor({ timeout: 60_000 });
    for (let tries = 0; !play!.socket && tries < 600; tries++) await paint(page, 1);
    if (!play!.socket) throw new Error(`${log.name}: the pane never attached`);
    await rest(page);
    const heapBefore = await heapMb(cdp);
    const since = await page.evaluate(() => performance.now());
    const bursts: BurstResult[] = [];
    const inBurst = new Map<number, (typeof log.bursts)[number]>();
    for (const burst of log.bursts) inBurst.set(burst.fromSeq, burst);
    const burstWindows: [number, number][] = [];
    let index = 0;
    while (index < log.events.length) {
      const burst = inBurst.get(log.events[index]!.seq);
      if (burst) {
        await paint(page, 2);
        if (PROFILE) await cdp.send("Profiler.start");
        const taskBefore = await metric(cdp, "TaskDuration");
        const windowStart = await page.evaluate(() => performance.now());
        for (; index < log.events.length && log.events[index]!.seq <= burst.toSeq; index++) {
          const event = log.events[index]!;
          await clockTo(page, event.at);
          play!.served = event.seq;
          emit(event);
          await paint(page, 1);
        }
        await paint(page, 2);
        const taskMs = ((await metric(cdp, "TaskDuration")) - taskBefore) * 1000;
        const records = burst.toSeq - burst.fromSeq + 1;
        const profiled = PROFILE ? ((await cdp.send("Profiler.stop")) as { profile: CpuProfile }).profile : undefined;
        burstWindows.push([windowStart, await page.evaluate(() => performance.now())]);
        bursts.push({
          kind: burst.kind,
          rows: burst.rows,
          msPerRecord: Math.round((taskMs / records) * 1000) / 1000,
          ...(profiled ? { selfMs: selfTimes(profiled, records) } : {}),
        });
        continue;
      }
      const batch: EventRecord[] = [];
      while (index < log.events.length && batch.length < BATCH && !inBurst.has(log.events[index]!.seq))
        batch.push(log.events[index++]!);
      await clockTo(page, batch.at(-1)!.at);
      for (const event of batch) {
        play!.served = event.seq;
        emit(event);
      }
      await paint(page, 1);
    }
    play!.status = "idle";
    changed(play!);
    await rest(page);
    let idleMsPerS = 0;
    if (measureIdle) {
      // Two seconds more first: a chat's own settling (fold timers, deferred measurement) is not idle work.
      await page.waitForTimeout(2000);
      const idleBefore = await metric(cdp, "TaskDuration");
      await page.waitForTimeout(3000);
      idleMsPerS = (((await metric(cdp, "TaskDuration")) - idleBefore) * 1000) / 3;
    }
    const heapAfter = await heapMb(cdp);
    const { shifts, long } = await page.evaluate((since) => {
      const w = window as unknown as { __shifts: Shift[]; __long: { at: number; ms: number }[] };
      return { shifts: w.__shifts.filter((shift) => !shift.input && shift.at >= since), long: w.__long };
    }, since);
    const burstLong = long.filter((task) => burstWindows.some(([from, to]) => task.at >= from && task.at <= to));
    return {
      log: log.name,
      cls: Math.round(shifts.reduce((sum, shift) => sum + shift.value, 0) * 1e4) / 1e4,
      longTasks: burstLong.length,
      longestTaskMs: Math.round(Math.max(0, ...long.map((task) => task.ms))),
      bursts,
      heapMb: Math.round((heapAfter - heapBefore) * 10) / 10,
      idleMsPerS: Math.round(idleMsPerS * 100) / 100,
      seconds: Math.round((performance.now() - started) / 100) / 10,
      shiftNotes: shiftSources(shifts),
    };
  } finally {
    await page.close();
  }
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) / 2)] ?? 0;
const worst = (values: number[]) => Math.max(0, ...values);

/// The rows and the budget misses of a run (pure).
export function judge(opens: Open[], lives: Live[]): { rows: PerfRow[]; misses: string[] } {
  const rows: PerfRow[] = [];
  const misses: string[] = [];
  const row = (r: PerfRow, why: string) => {
    rows.push(r);
    if (r.target !== undefined && r.p95 > r.target)
      misses.push(`BUDGET MISS ${r.name} = ${r.p95} ${r.unit ?? "ms"} (budget ${r.target}): ${why}`);
  };
  if (opens.length) {
    const cls = opens.map((o) => o.cls);
    const moved = opens.map((o) => o.moved);
    const worstCls = opens.reduce((a, b) => (b.cls > a.cls ? b : a));
    const worstMove = opens.reduce((a, b) => (b.moved > a.moved ? b : a));
    row(
      {
        name: "transcript_replay.open.cls",
        p50: median(cls),
        p95: worst(cls),
        unit: "score",
        target: BUDGET.cls,
        floor: 0.001,
      },
      `opening ${worstCls.log} shifted the layout after its first paint (${worstCls.shiftNotes.join("; ") || "no sources"})`,
    );
    row(
      {
        name: "transcript_replay.open.moved_px",
        p50: median(moved),
        p95: worst(moved),
        unit: "px",
        target: BUDGET.movedPx,
        floor: 1,
      },
      `opening ${worstMove.log}, row ${worstMove.movedRow} moved after the first frame: the first frame was not the final frame`,
    );
  }
  if (lives.length) {
    const cls = lives.map((l) => l.cls);
    const worstCls = lives.reduce((a, b) => (b.cls > a.cls ? b : a));
    row(
      {
        name: "transcript_replay.live.cls",
        p50: median(cls),
        p95: worst(cls),
        unit: "score",
        target: BUDGET.cls,
        floor: 0.001,
      },
      `streaming ${worstCls.log} shifted rows already painted (${worstCls.shiftNotes.join("; ") || "no sources"})`,
    );
    const long = lives.map((l) => l.longTasks);
    row(
      {
        name: "transcript_replay.live.long_tasks",
        p50: median(long),
        p95: worst(long),
        unit: "count",
        target: BUDGET.longTasks,
        floor: 0.5,
      },
      `a streamed token or tool update took a task over 50 ms (longest ${worst(lives.map((l) => l.longestTaskMs))} ms)`,
    );
  }
  const longLive = lives.find((l) => l.log === "long");
  if (longLive) {
    for (const kind of ["token", "tool_output"] as const) {
      const points = longLive.bursts
        .filter((b) => b.kind === kind)
        .map((b) => ({ x: b.rows / 1000, y: b.msPerRecord }));
      if (!points.length) continue;
      const ms = points.map((p) => p.y);
      row(
        {
          name: `transcript_replay.long.${kind}_ms`,
          p50: median(ms),
          p95: worst(ms),
          target: TARGET_MS.frameWork,
          floor: 0.5,
        },
        `one ${kind === "token" ? "reply token" : "tool output update"} costs more main-thread time than a frame's work`,
      );
      const growth = Math.round(slope(points) * 1000) / 1000;
      row(
        {
          name: `transcript_replay.long.${kind}_slope_ms_per_krow`,
          p50: growth,
          p95: growth,
          target: BUDGET.slope,
          floor: 0.05,
        },
        `each ${kind === "token" ? "token" : "tool output update"} costs ${growth} ms more per 1000 rows already in the ` +
          `transcript (${points.map((p) => `${Math.round(p.x * 1000)} rows: ${p.y} ms`).join(", ")}): O(rows) work per update`,
      );
    }
    row(
      {
        name: "transcript_replay.long.heap_mb",
        p50: longLive.heapMb,
        p95: longLive.heapMb,
        unit: "MB",
        target: BUDGET.heapMb,
        floor: 4,
      },
      `the long chat holds ${longLive.heapMb} MB of JS heap after GC`,
    );
    row(
      {
        name: "transcript_replay.long.idle_ms_per_s",
        p50: longLive.idleMsPerS,
        p95: longLive.idleMsPerS,
        target: BUDGET.idleMsPerS,
        floor: 0.5,
      },
      `the pane keeps working (${longLive.idleMsPerS} ms each second) after the replay settled: idle CPU`,
    );
  }
  return { rows, misses };
}

if (import.meta.main) {
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
    const now = Date.now();
    const logs: ReplayLog[] = [];
    if (ONLY.includes("long")) logs.push(longLog({ turns: TURNS }));
    if (ONLY.includes("recorded")) logs.push(recordedLog());
    if (ONLY.includes("mock")) logs.push(...mockLogs(now));
    for (const file of LOG_FILES) logs.push(parseLog(path.basename(file), fs.readFileSync(file, "utf8")));
    for (const log of logs) checkSeq(log);
    const daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.method === "_acpmux/attach" && play) play.socket = ws;
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "transcript-replay-bench-"));
    releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const builtAt = performance.now();
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false } : {}) },
      logLevel: "error",
    });
    console.log(`transcript-replay: pane built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
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
    const browser = await chromium.launch({
      ...(process.env.CMUX_CHROME_HEADLESS_SHELL
        ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
        : { channel: "chrome" }),
      headless: true,
    });
    releases.push(() => browser.close());
    const ctx: Ctx = {
      browser,
      url: (log) =>
        `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${encodeURIComponent(log.sessionId)}`,
    };
    let failed = 0;
    const opens: Open[] = [];
    const lives: Live[] = [];
    for (const log of logs) {
      try {
        const open = await openRound(ctx, log);
        opens.push(open);
        // A seeded chat of a prompt and its reply streams in too few records to say anything live; the open covers it.
        const live =
          log.name.startsWith("mock:") && log.events.length < 8
            ? undefined
            : await liveRound(ctx, log, log.name === "long");
        if (live) lives.push(live);
        console.log(
          `transcript-replay: ${log.name} (${log.events.length} records, ${rowsIn(log.events)} rows) open cls ${open.cls} ` +
            `moved ${open.moved} px (${open.movedRow})` +
            (live
              ? ` | live ${live.seconds} s cls ${live.cls} long tasks ${live.longTasks} (longest ${live.longestTaskMs} ms) ` +
                `heap +${live.heapMb} MB` +
                (log.name === "long" ? ` idle ${live.idleMsPerS} ms/s` : "")
              : ""),
        );
        for (const note of [
          ...open.shiftNotes.map((n) => `open shift: ${n}`),
          ...(live?.shiftNotes ?? []).map((n) => `live shift: ${n}`),
        ])
          if (!note.includes(" 0.0000 ")) console.log(`  ${note}`);
        for (const burst of live?.bursts ?? [])
          console.log(`  ${burst.kind} at ${burst.rows} rows: ${burst.msPerRecord} ms per record`);
        for (const kind of ["token", "tool_output"]) {
          const profiled = (live?.bursts ?? []).filter((burst) => burst.kind === kind && burst.selfMs);
          if (profiled.length < 2) continue;
          const [first, last] = [profiled[0]!, profiled.at(-1)!];
          console.log(`  ${kind}: self ms per record that grew from ${first.rows} rows to ${last.rows} rows`);
          for (const [fn, before, after] of grew(first.selfMs!, last.selfMs!))
            console.log(`    ${before.toFixed(3)} -> ${after.toFixed(3)}  ${fn}`);
        }
      } catch (error) {
        failed += 1;
        console.log(`transcript-replay: ${log.name} FAILED: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    const { rows, misses } = judge(opens, lives);
    for (const each of rows) perfRow(each);
    for (const miss of misses) console.log(`transcript-replay: ${miss}`);
    if (!misses.length) console.log("transcript-replay: every budget held");
    if (failed || (STRICT && misses.length)) process.exitCode = 1;
  } finally {
    await release();
  }
}
