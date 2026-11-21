// l10n-allow-file: benchmark output, not shipped UI.
// A burst of tool calls arriving in a running turn, on the wall clock, as an agent sends them: how smooth the pane
// stays while they land. Leo, 2026-11-11: "the tool calls coming in are still kinda sluggish... are ther ways to make
// that smooth and performant?"
// transcript-replay.bench.ts plays one record per painted frame and counts main-thread ms per record; an agent does
// not wait for frames. Here the stand-in acpmux sends each record on its own timer (`--gap` ms between calls, each
// call a start, for a shell call two output updates, and an end), so records land between frames, several in one
// frame, as they do in the app. A chat of `--turns` finished turns (loadFixture.ts) comes first, attached whole.
// Rows (Chromium only for long tasks and task time):
//   tool_call_burst.<pace>.frame_gap_ms     rAF interval p50 / p95 while the burst plays (16.7 ms is every frame)
//   tool_call_burst.<pace>.long_tasks       long tasks (> 50 ms) while the burst plays
//   tool_call_burst.<pace>.event_to_paint_ms  a record's arrival on the socket to the first frame after the DOM
//                                           changed for it, p50 / p95
//   tool_call_burst.<pace>.task_ms_per_call main-thread task ms per tool call (start, updates and end)
//   tool_call_burst.<pace>.cls              layout-shift sum while the burst plays
// Under load (CMUX-571: Leo's NIGHTLY on a loaded Mac drew 4 fps, and a record waited p50 1,021 ms, p95 1,837 ms from
// its arrival to its first paint while applying it took 2.6 ms at most), `--cpu N` slows the page's CPU N times (CDP
// Emulation.setCPUThrottlingRate) once the chat is open, and `--hog N` runs N busy processes on the host for the
// burst. Each round also prints, beside the rows above (printed only, no rows):
//   capture p50/p95   the page's own `cmux app chat perf` capture (chatPerfCapture.ts, the NIGHTLY's numbers) over
//                     the burst: a record's arrival to the first frame painted after it
//   commit p50/p95    a record's arrival to the DOM change after it (ms)
//   missed            records whose DOM change came only after a frame that began after they arrived: a frame
//                     that could have shown the record and did not
// A DOM change made in a frame callback, or in the microtasks right after one, is painted by that frame.
//   bun bench/tool-call-burst.bench.ts [--turns 200] [--calls 50] [--paces fast:15,agent:60] [--rounds 3]
//     [--cpu 1] [--hog 0]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Browser, CDPSession, Page } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { loadTurn, sourceFile } from "../src/agent-session/acpmux/loadFixture";
import { perfRow, TARGET_MS } from "./perfRow";
import { toRecord, type Step } from "./replayLogs";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const TURNS = Number(flag("--turns") ?? 200);
const CALLS = Number(flag("--calls") ?? 50);
const ROUNDS = Number(flag("--rounds") ?? 3);
const PACES = (flag("--paces") ?? "fast:15,agent:60").split(",").map((pair) => {
  const [name, gap] = pair.split(":");
  return { name: name!, gap: Number(gap) };
});
const PROFILE = process.env.PROFILE === "1";
/// The page's CPU slowed this many times for the burst (1: as it is).
const CPU = Number(flag("--cpu") ?? 1);
/// Busy processes on the host while the burst plays (0: none).
const HOG = Number(flag("--hog") ?? 0);
const webviews = path.resolve(import.meta.dir, "..");
const sessionId = "tool-burst";

/// The chat before the burst: `TURNS` finished turns, then the running turn's prompt.
function prefix(start: number): EventRecord[] {
  const events: EventRecord[] = [];
  const push = (at: number, step: Step) => events.push(toRecord(sessionId, events.length + 1, at, step));
  for (let turn = 0; turn < TURNS; turn += 1)
    for (const step of loadTurn(turn)) push(start + turn * 60_000, step as Step);
  const at = start + TURNS * 60_000;
  push(at, { mux: "user_message", msg: { text: "Run the checks one by one and fix what fails" } });
  push(at, { mux: "turn_started" });
  push(at + 500, {
    update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "I'll go through them." } },
  });
  return events;
}

/// One call's records, as steps with their offset (ms) from the call's start: a read, a shell call that streams two
/// output updates, an edit, or a search, in turn.
function call(index: number, gap: number): { after: number; step: Step }[] {
  const id = `burst-${index}`;
  const file = `src/feature${index % 40}/step${index}.ts`;
  const kind = (["read", "execute", "edit", "search"] as const)[index % 4]!;
  const end = Math.max(1, Math.floor(gap * 0.6));
  const done = (content: unknown[]) => ({
    update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", content },
  });
  const text = (value: string) => [{ type: "content", content: { type: "text", text: value } }];
  if (kind === "read")
    return [
      {
        after: 0,
        step: {
          update: {
            sessionUpdate: "tool_call",
            toolCallId: id,
            kind,
            title: `Read ${file}`,
            status: "in_progress",
            locations: [{ path: `/mock/project/${file}` }],
          },
        },
      },
      { after: end, step: done(text(sourceFile(index, 30))) },
    ];
  if (kind === "execute") {
    const command = `bun test src/feature${index % 40}`;
    let log = "";
    const lines = (from: number) => {
      for (let line = from; line < from + 20; line += 1)
        log += `✓ case ${line} keeps the cache stable [0.${line % 9}ms]\n`;
      return log;
    };
    return [
      {
        after: 0,
        step: {
          update: {
            sessionUpdate: "tool_call",
            toolCallId: id,
            kind,
            title: `Run ${command}`,
            status: "in_progress",
            rawInput: { command },
          },
        },
      },
      {
        after: Math.floor(end / 3),
        step: {
          update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "in_progress", content: text(lines(0)) },
        },
      },
      {
        after: Math.floor((end * 2) / 3),
        step: {
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: id,
            status: "in_progress",
            content: text(lines(20)),
          },
        },
      },
      { after: end, step: done(text(lines(40))) },
    ];
  }
  if (kind === "edit") {
    const before = sourceFile(index, 24);
    const after = before.replace(/limit/g, "ceiling");
    return [
      {
        after: 0,
        step: {
          update: {
            sessionUpdate: "tool_call",
            toolCallId: id,
            kind,
            title: `Edit ${file}`,
            status: "in_progress",
            locations: [{ path: `/mock/project/${file}`, line: 1 }],
          },
        },
      },
      { after: end, step: done([{ type: "diff", path: `/mock/project/${file}`, oldText: before, newText: after }]) },
    ];
  }
  return [
    {
      after: 0,
      step: {
        update: {
          sessionUpdate: "tool_call",
          toolCallId: id,
          kind,
          title: `Search "limit" in src/feature${index % 40}`,
          status: "in_progress",
        },
      },
    },
    {
      after: end,
      step: done(text(`src/feature${index % 40}/a.ts:12: limit\nsrc/feature${index % 40}/b.ts:40: limit\n`)),
    },
  ];
}

// ---------- the stand-in acpmux ----------
type Play = { events: EventRecord[]; served: number; status: string; socket?: { send(data: string): void } };
let play: Play | undefined;
const summary = (p: Play) => ({
  sessionId,
  cwd: "/mock/project",
  title: "Tool call burst",
  harness: "claude",
  name: "claude",
  status: p.status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: TURNS + 1,
  updatedAt: p.events.at(-1)?.at ?? Date.now(),
});
function answer(method: string): unknown {
  const p = play!;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary(p)] };
    case "_acpmux/attach":
      return { session: summary(p), lastSeq: p.served, events: p.events.slice(0, p.served) };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: p.served };
    default:
      return null;
  }
}
const emit = (event: EventRecord) =>
  play?.socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));

// ---------- the page side ----------
/** Init script: frame times, long tasks, layout shifts, record arrivals and DOM change times. Self-contained. */
function instrument() {
  const w = window as unknown as {
    __frames: number[];
    __long: { at: number; ms: number }[];
    __shifts: { at: number; value: number }[];
    __arrivals: number[];
    __mutations: number[];
    /// Per DOM change: the frame (its rAF timestamp) whose callbacks made it, or -1 when a task made it.
    __mutationFrames: number[];
    __watch: () => void;
  };
  if (w.__frames) return;
  w.__frames = [];
  w.__long = [];
  w.__shifts = [];
  w.__arrivals = [];
  w.__mutations = [];
  w.__mutationFrames = [];
  // A DOM change in a frame callback, or in the microtasks right after it (a store's sync render), is drawn by
  // that frame: every frame callback is wrapped to take the observer's records before the frame renders.
  let observer: MutationObserver | undefined;
  const note = (frameAt: number) => {
    if (!observer || observer.takeRecords().length === 0) return;
    w.__mutations.push(performance.now());
    w.__mutationFrames.push(frameAt);
  };
  const realFrame = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (callback: FrameRequestCallback) =>
    realFrame((at) => {
      try {
        callback(at);
      } finally {
        note(at);
        queueMicrotask(() => note(at));
      }
    });
  const frame = (at: number) => {
    w.__frames.push(at);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as {
        startTime: number;
        value: number;
        hadRecentInput: boolean;
      }[])
        if (!entry.hadRecentInput) w.__shifts.push({ at: entry.startTime, value: entry.value });
    }).observe({ type: "layout-shift", buffered: true });
  } catch {
    // An engine without them reads 0.
  }
  // Each `_acpmux/event` as it arrives, before the page's own handler runs.
  const Real = window.WebSocket;
  class Watched extends Real {
    constructor(url: string | URL, protocols?: string | string[]) {
      super(url, protocols);
      this.addEventListener("message", (event) => {
        if (typeof event.data === "string" && event.data.includes('"_acpmux/event"'))
          w.__arrivals.push(performance.now());
      });
    }
  }
  (window as unknown as { WebSocket: typeof WebSocket }).WebSocket = Watched;
  w.__watch = () => {
    const root = document.querySelector(".acpmux-scroll") ?? document.body;
    observer = new MutationObserver((records) => {
      if (records.length === 0) return;
      w.__mutations.push(performance.now());
      w.__mutationFrames.push(-1);
    });
    observer.observe(root, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  };
}

const percentile = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! : 0;
};
const r1 = (value: number) => Math.round(value * 10) / 10;

async function metric(cdp: CDPSession, name: string): Promise<number> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((each) => each.name === name)?.value ?? 0;
}

type Round = {
  frameP50: number;
  frameP95: number;
  frameMax: number;
  longTasks: number;
  longestTask: number;
  paintP50: number;
  paintP95: number;
  taskMsPerCall: number;
  cls: number;
  commitP50: number;
  commitP95: number;
  missed: number;
  records: number;
  captureP50: number | null;
  captureP95: number | null;
  captureCount: number | null;
  selfMs?: [string, number][];
};

type Capture = { records?: { all?: { count?: number; to_paint?: { p50_ms?: number; p95_ms?: number } } } } | null;

type CpuProfile = {
  nodes: {
    id: number;
    callFrame: { functionName: string; url: string; lineNumber: number };
    children?: number[];
  }[];
  samples: number[];
  timeDeltas: number[];
};
/// Self ms per function; a native one (a layout read, getAnimations) is keyed with the JS functions that called it,
/// so a forced layout names its reader.
function selfTimes(profile: CpuProfile): [string, number][] {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const name = (frame: CpuProfile["nodes"][number]["callFrame"]) => {
    const file = frame.url.split("/").pop() ?? "";
    return `${frame.functionName || "(anon)"}${file ? ` ${file}:${frame.lineNumber + 1}` : ""}`;
  };
  const sum = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.functionName === "(idle)" || frame.functionName === "(program)") return;
    let key = name(frame);
    if (!frame.url) {
      const callers: string[] = [];
      for (let up = parent.get(id); up !== undefined && callers.length < 3; up = parent.get(up)) {
        const caller = byId.get(up)?.callFrame;
        if (caller?.url) callers.push(name(caller));
      }
      if (callers.length) key += ` <- ${callers.join(" <- ")}`;
    }
    sum.set(key, (sum.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
  });
  return [...sum.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40);
}

async function round(browser: Browser, url: string, gap: number): Promise<Round> {
  const start = Date.now() - (TURNS + 1) * 60_000;
  const events = prefix(start);
  play = { events, served: events.length, status: "running" };
  const page: Page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  try {
    await page.addInitScript(instrument);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    if (PROFILE) await cdp.send("Profiler.enable");
    await page.goto(url);
    await page.locator("[data-row-id]").first().waitFor({ timeout: 60_000 });
    for (let tries = 0; !play.socket && tries < 600; tries++) await page.waitForTimeout(20);
    if (!play.socket) throw new Error("the pane never attached");
    await page.waitForTimeout(1500);
    await page.evaluate(() => (window as unknown as { __watch: () => void }).__watch());
    if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
    // The burst: each record on its own wall-clock timer.
    const schedule: { at: number; step: Step }[] = [];
    for (let index = 0; index < CALLS; index += 1)
      for (const { after, step } of call(index, gap)) schedule.push({ at: index * gap + after, step });
    schedule.sort((a, b) => a.at - b.at);
    // Busy processes for the burst, each stopped by its own handle.
    const hogs = Array.from({ length: HOG }, () =>
      Bun.spawn([process.execPath, "-e", "for (;;) {}"], { stdout: "ignore", stderr: "ignore" }),
    );
    let capture: Promise<Capture> = Promise.resolve(null);
    try {
      const since = await page.evaluate(() => performance.now());
      const taskBefore = await metric(cdp, "TaskDuration");
      if (PROFILE) await cdp.send("Profiler.start");
      // The page's own capture over the whole burst and the second after it (seconds, at most 60).
      const seconds = Math.min(60, Math.ceil(((schedule.at(-1)?.at ?? 0) + 1000) / 1000));
      capture = page.evaluate(
        (window_) =>
          (
            window as unknown as {
              cmuxAcpmuxBridge?: { perfCapture?(o: { seconds: number }): Promise<Record<string, unknown>> };
            }
          ).cmuxAcpmuxBridge?.perfCapture?.({ seconds: window_ }) ?? null,
        seconds,
      ) as Promise<Capture>;
      const t0 = performance.now();
      for (const { at, step } of schedule) {
        const wait = t0 + at - performance.now();
        if (wait > 0) await Bun.sleep(wait);
        const record = toRecord(sessionId, play.served + 1, Date.now(), step);
        play.events.push(record);
        play.served += 1;
        emit(record);
      }
      await page.waitForTimeout(1000);
      return await measured(page, cdp, since, taskBefore, await capture);
    } finally {
      for (const hog of hogs) hog.kill();
    }
  } finally {
    await page.close();
  }
}

async function measured(
  page: Page,
  cdp: CDPSession,
  since: number,
  taskBefore: number,
  capture: Capture,
): Promise<Round> {
  const profiled = PROFILE ? ((await cdp.send("Profiler.stop")) as { profile: CpuProfile }).profile : undefined;
  const taskMs = ((await metric(cdp, "TaskDuration")) - taskBefore) * 1000;
  const until = await page.evaluate(() => performance.now());
  const data = await page.evaluate(() => {
    const w = window as unknown as {
      __frames: number[];
      __long: { at: number; ms: number }[];
      __shifts: { at: number; value: number }[];
      __arrivals: number[];
      __mutations: number[];
      __mutationFrames: number[];
    };
    return {
      frames: w.__frames,
      long: w.__long,
      shifts: w.__shifts,
      arrivals: w.__arrivals,
      mutations: w.__mutations,
      mutationFrames: w.__mutationFrames,
    };
  });
  const arrivals = data.arrivals.filter((at) => at >= since);
  const lastArrival = arrivals.at(-1) ?? until;
  const frames = data.frames.filter((at) => at >= since && at <= lastArrival + 200);
  const gaps = frames.slice(1).map((at, index) => at - frames[index]!);
  // A record's arrival to the frame that draws the first DOM change at or after the arrival: the frame whose
  // callbacks made the change, else the first frame that begins after it.
  const paints: number[] = [];
  const commits: number[] = [];
  let missed = 0;
  let m = 0;
  let f = 0;
  for (const arrival of arrivals) {
    while (m < data.mutations.length && data.mutations[m]! < arrival) m++;
    const changed = data.mutations[m];
    if (changed === undefined) continue;
    commits.push(changed - arrival);
    const inFrame = data.mutationFrames[m] ?? -1;
    while (f < data.frames.length && data.frames[f]! <= changed) f++;
    // A change made in a frame's callbacks is drawn by that frame, which presents right after them (`changed`, the
    // end of those callbacks; the frame's own timestamp is its begin time, which can be before the record came). A
    // change made in a task waits for the next frame.
    const drawnBy = inFrame >= 0 ? inFrame : data.frames[f];
    const painted = inFrame >= 0 ? changed : data.frames[f];
    if (painted === undefined || drawnBy === undefined) continue;
    paints.push(painted - arrival);
    // A frame began after the record came and before the frame that draws it: one the record waited past.
    if (data.frames.some((at) => at > arrival && at < drawnBy)) missed += 1;
  }
  const long = data.long.filter((task) => task.at >= since && task.at <= lastArrival + 200);
  const all = capture?.records?.all;
  return {
    frameP50: r1(percentile(gaps, 0.5)),
    frameP95: r1(percentile(gaps, 0.95)),
    frameMax: r1(Math.max(0, ...gaps)),
    longTasks: long.length,
    longestTask: Math.round(Math.max(0, ...long.map((task) => task.ms))),
    paintP50: r1(percentile(paints, 0.5)),
    paintP95: r1(percentile(paints, 0.95)),
    taskMsPerCall: r1(taskMs / CALLS),
    cls: Math.round(data.shifts.filter((s) => s.at >= since).reduce((sum, s) => sum + s.value, 0) * 1e4) / 1e4,
    commitP50: r1(percentile(commits, 0.5)),
    commitP95: r1(percentile(commits, 0.95)),
    missed,
    records: paints.length,
    captureP50: all?.to_paint?.p50_ms ?? null,
    captureP95: all?.to_paint?.p95_ms ?? null,
    captureCount: all?.count ?? null,
    ...(profiled ? { selfMs: selfTimes(profiled) } : {}),
  };
}

if (import.meta.main) {
  const releases: (() => unknown)[] = [];
  try {
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
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "tool-call-burst-bench-"));
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
    const browser = await chromium.launch({
      headless: true,
    });
    releases.push(() => browser.close());
    const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId}`;
    for (const pace of PACES) {
      const rounds: Round[] = [];
      for (let index = 0; index < ROUNDS; index += 1) rounds.push(await round(browser, url, pace.gap));
      const med = (pick: (r: Round) => number) => percentile(rounds.map(pick), 0.5);
      const worst = (pick: (r: Round) => number) => Math.max(...rounds.map(pick));
      console.log(
        `tool-call-burst: ${pace.name} (${CALLS} calls, ${pace.gap} ms apart, ${TURNS} turns before) ` +
          rounds
            .map(
              (r) =>
                `[frame p50 ${r.frameP50} p95 ${r.frameP95} max ${r.frameMax} | long ${r.longTasks} (${r.longestTask} ms) | ` +
                `paint p50 ${r.paintP50} p95 ${r.paintP95} | commit p50 ${r.commitP50} p95 ${r.commitP95} | ` +
                `missed ${r.missed}/${r.records} | capture p50 ${r.captureP50} p95 ${r.captureP95} (${r.captureCount}) | ` +
                `${r.taskMsPerCall} ms/call | cls ${r.cls}]`,
            )
            .join(" "),
      );
      console.log(
        `tool-call-burst: ${pace.name} cpu ${CPU}x hog ${HOG} median of ${ROUNDS}: frame p50 ${med((r) => r.frameP50)} ` +
          `p95 ${med((r) => r.frameP95)} | paint p50 ${med((r) => r.paintP50)} p95 ${med((r) => r.paintP95)} | ` +
          `commit p50 ${med((r) => r.commitP50)} p95 ${med((r) => r.commitP95)} | ` +
          `missed ${med((r) => r.missed / Math.max(1, r.records)).toFixed(2)} | ` +
          `capture p50 ${med((r) => r.captureP50 ?? NaN)} p95 ${med((r) => r.captureP95 ?? NaN)}`,
      );
      for (const r of rounds.filter((r) => r.selfMs).slice(0, 1))
        for (const [fn, ms] of r.selfMs!) console.log(`    ${ms.toFixed(1)} ms  ${fn}`);
      // A loaded run is a diagnosis, printed above; its rows would read as the idle runner's.
      if (CPU > 1 || HOG > 0) continue;
      const name = `tool_call_burst.${pace.name}`;
      perfRow({ name: `${name}.frame_gap_ms`, p50: med((r) => r.frameP50), p95: med((r) => r.frameP95), target: 33.4 });
      perfRow({
        name: `${name}.long_tasks`,
        p50: med((r) => r.longTasks),
        p95: worst((r) => r.longTasks),
        unit: "count",
        target: 0,
      });
      perfRow({
        name: `${name}.event_to_paint_ms`,
        p50: med((r) => r.paintP50),
        p95: med((r) => r.paintP95),
        target: TARGET_MS.response,
      });
      perfRow({
        name: `${name}.task_ms_per_call`,
        p50: med((r) => r.taskMsPerCall),
        p95: worst((r) => r.taskMsPerCall),
        clock: "cpu",
      });
      perfRow({ name: `${name}.cls`, p50: med((r) => r.cls), p95: worst((r) => r.cls), unit: "score", target: 0.01 });
    }
  } finally {
    for (const stop of releases.reverse()) {
      try {
        await stop();
      } catch {
        // Release the rest.
      }
    }
  }
}
