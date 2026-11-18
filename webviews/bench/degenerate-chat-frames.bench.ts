// l10n-allow-file: benchmark output, not shipped UI.
// The degenerate lab's frame bench: what one agent chat pane's frames cost when the chat is huge (Leo, 2026-11-12:
// "simulate fps under load ... simulate streaming text ... truly degenerated cases/states"; "even if a chat is long,
// there should be no percievable difference"). The real pane (a vite build of vite.config.acpmux-pane.mjs, as
// transcript-replay.bench.ts builds it) joins a stand-in acpmux that answers initialize, `_acpmux/watch`,
// `_acpmux/attach` and `_acpmux/events` with the pages the daemon would send (daemonPage.ts), in headless Chromium.
// Every fixture (godFixture.ts's small and god chats, and each `--log FILE`) runs the same phases in the same harness:
//   open        a new page (its own context: nothing cached) navigated to the chat; `first_content_ms` is navigation
//               start to the first painted frame showing a transcript row, then the frames of the 2 s after it
//   scroll      wheel input over the transcript, upward through history from the newest row, one wheel step of
//               --wheel px per painted frame for --steps steps (older pages load as the daemon pages them)
//   fling       the pane's own debug fling (cmuxAcpmuxDebug.startFling: bottom to top of what is loaded, --fling s)
//   stream_<tps>tps[_<n>chats]   in a second fresh page: a new turn whose reply streams as `_acpmux/event`
//               agent_message_chunk notifications of about 4 characters each, paced by wall clock at that rate, for
//               --stream-s seconds; with --chats N the list watch holds N-1 other chats that stream too, each token
//               a `_acpmux/session_changed` for that chat (the only thing a daemon sends a pane about a chat it has
//               not attached)
// Each phase: the intervals between painted frames (test/support/paintedFrames.ts, one rAF timestamp per frame),
// their p50/p95/p99/max and the FPS they make, and long tasks (PerformanceObserver `longtask`: count, total ms).
// Headless Chromium has no display refresh, so no row counts dropped frames: a frame interval past ~16.7 ms is a
// frame the main thread or the compositor held up.
// Rows (bench/perfRow.ts; lower is better for every row, so FPS goes in the table and the JSON, not in a row):
//   degenerate.open.<fixture>.first_content_ms
//   degenerate.<phase>.<fixture>.interval_p50_ms / interval_p95_ms / interval_p99_ms / interval_max_ms
//   degenerate.<phase>.<fixture>.long_tasks (count) / long_task_ms (total)
// --out FILE writes the JSON: every phase's numbers, the perf rows, and `rows`, the god-vs-small pairs in the schema
// scripts/cmux-next/quality-report.py --god-small reads ({"name", "small_p95", "god_p95"}; name drops the fixture).
// --trace DIR records a Chrome trace of each of the god run's phases (devtools.timeline, the frame category and the
// V8 sampling profiler) to DIR/god-<phase>.json, and prints each phase's functions by self time, mapped back to
// webviews/src through the build's source map. Tracing costs the traced run some time; compare god with small
// without it.
//   bun bench/degenerate-chat-frames.bench.ts [--scale god|small] [--log FILE]... [--tps 50,500] [--chats 1]
//     [--steps 300] [--wheel 120] [--fling 3] [--stream-s 5] [--out FILE] [--trace DIR]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import type { ServerWebSocket } from "bun";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { percentile, round2 } from "../src/agent-session/acpmux/perf";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { newestPage } from "./daemonPage";
import { godLog, LATEST_TEXT, SCALES, type Scale } from "./godFixture";
import { perfRow, TARGET_MS, type PerfRow } from "./perfRow";
import { checkSeq, parseLog, rowsIn, toRecord, tokens, type ReplayLog } from "./replayLogs";
import { sourceMapper } from "./sourceMapper";
import { instrument, rest } from "./transcript-replay.bench";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const num = (name: string, fallback: number) => {
  const value = Number(flag(name) ?? fallback);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive number`);
  return value;
};
const SCALE = flag("--scale");
if (SCALE !== undefined && !(SCALES as readonly string[]).includes(SCALE)) throw new Error("--scale is god or small");
const LOG_FILES = argv.flatMap((arg, index) => (argv[index - 1] === "--log" ? [arg] : []));
const TPS = (flag("--tps") ?? "50,500").split(",").map(Number);
if (TPS.some((tps) => !Number.isFinite(tps) || tps <= 0)) throw new Error("--tps is a list of positive rates");
const CHATS = Math.floor(num("--chats", 1));
const STEPS = Math.floor(num("--steps", 300));
const WHEEL_PX = num("--wheel", 120);
const FLING_S = num("--fling", 3);
const STREAM_S = num("--stream-s", 5);
const OPEN_WINDOW_MS = 2000;
const OUT = flag("--out");
const TRACE_DIR = flag("--trace");
const webviews = path.resolve(import.meta.dir, "..");
const TRACE_CATEGORIES = [
  "devtools.timeline",
  "disabled-by-default-devtools.timeline.frame",
  "v8.cpu_profiler",
  "disabled-by-default-v8.cpu_profiler",
];

// ---------- the stand-in acpmux ----------
type Fixture = { name: string; log: ReplayLog; latest?: string };
/// The chat the stand-in serves: the fixture's records and whatever this page's turns streamed after them.
type Served = { fixture: Fixture; events: EventRecord[]; status: string; turnCount: number; attached?: Socket };
type Socket = ServerWebSocket<undefined>;
let served: Served | undefined;
const sockets = new Set<Socket>();
const otherIds = () => Array.from({ length: CHATS - 1 }, (_, index) => `degenerate-other-${index + 1}`);
const otherLastSeq = new Map<string, number>();

const summary = (s: Served) => ({
  ...s.fixture.log.summary,
  family: "claude",
  status: s.status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: s.turnCount,
  updatedAt: s.events.at(-1)?.at ?? Date.now(),
  lastSeq: s.events.at(-1)?.seq ?? 0,
});
const otherSummary = (id: string, s: Served, status = "idle") => ({
  sessionId: id,
  cwd: "/mock/project",
  title: `Other chat ${id.split("-").pop()}`,
  harness: "claude",
  name: "claude",
  family: "claude",
  status,
  turnCount: 3,
  createdAt: s.events[0]?.at ?? 0,
  updatedAt: s.events.at(-1)?.at ?? 0,
  lastSeq: otherLastSeq.get(id) ?? 12,
});

function answer(method: string, params: Record<string, unknown>): unknown {
  const s = served!;
  const lastSeq = s.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary(s), ...otherIds().map((id) => otherSummary(id, s))] };
    case "_acpmux/attach": {
      const { page, hasMore } = newestPage(s.events, { limit: Number(params.limit ?? 400), maxBytes: params.maxBytes });
      return { session: summary(s), lastSeq, events: page, hasMore };
    }
    case "_acpmux/events": {
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = s.events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newestPage(s.events, {
          limit: Number(params.limit ?? 400),
          beforeSeq: Number(params.beforeSeq),
          maxBytes: params.maxBytes,
        });
        return { events: page, hasMore, lastSeq };
      }
      return { events: [], hasMore: false, lastSeq };
    }
    default:
      return null;
  }
}
const notify = (socket: Socket | undefined, method: string, params: unknown) =>
  socket?.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
const broadcast = (method: string, params: unknown) => {
  for (const socket of sockets) notify(socket, method, params);
};
/// Appends a record to the served chat and sends it to the page that attached it.
function emit(step: Parameters<typeof toRecord>[3], at: number) {
  const s = served!;
  const record = toRecord(s.fixture.log.sessionId, (s.events.at(-1)?.seq ?? 0) + 1, at, step);
  s.events.push(record);
  notify(s.attached, "_acpmux/event", record);
}
const statusChanged = (status: string) => {
  const s = served!;
  s.status = status;
  broadcast("_acpmux/session_changed", {
    sessionId: s.fixture.log.sessionId,
    session: summary(s),
    kind: "status",
    seq: s.events.at(-1)?.seq ?? 0,
  });
};

// ---------- the page side ----------
type Win = Window & {
  __frames: number[];
  __firstContentAt?: number;
  __long: { at: number; ms: number }[];
  __replayAt: (at: number) => void;
  cmuxAcpmuxDebug?: {
    startFling(seconds?: number, options?: { nominal_ms?: number; wait?: boolean }): Promise<Record<string, unknown>>;
  };
};
/// Init script: every painted frame's time from the document's start, and the first that shows a transcript row.
/// Runs after installPaintedFrames' script (registered first), so `cmuxAfterPaint` is defined.
function recordFrames() {
  const w = window as unknown as Win;
  if (w.__frames) return;
  w.__frames = [];
  w.cmuxAfterPaint((frame) => {
    w.__frames.push(frame);
    if (w.__firstContentAt === undefined && document.querySelector(".acpmux-scroll [data-row-id]"))
      w.__firstContentAt = performance.now();
  });
}
/// Init script: the replay clock (transcript-replay's `instrument`) follows the wall clock from `start`.
function clockFollows(start: number) {
  const w = window as unknown as Win;
  setInterval(() => w.__replayAt(start + performance.now()), 50);
}

type Phase = {
  fixture: string;
  phase: string;
  frames: number;
  seconds: number;
  fps: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
  longTasks: number;
  longTaskMs: number;
  firstContentMs?: number;
  note?: string;
};

/// Frame intervals and long tasks between two page times (pure).
export function phaseStats(
  frames: readonly number[],
  long: readonly { at: number; ms: number }[],
  from: number,
  to: number,
): Omit<Phase, "fixture" | "phase"> {
  const inWindow = frames.filter((frame) => frame >= from && frame <= to);
  const intervals = inWindow.slice(1).map((frame, index) => frame - inWindow[index]!);
  const sorted = [...intervals].sort((a, b) => a - b);
  const span = (inWindow.at(-1) ?? 0) - (inWindow[0] ?? 0);
  const tasks = long.filter((task) => task.at >= from && task.at <= to);
  return {
    frames: inWindow.length,
    seconds: round2((to - from) / 1000),
    fps: span > 0 ? round2((intervals.length * 1000) / span) : 0,
    p50: round2(percentile(sorted, 0.5)),
    p95: round2(percentile(sorted, 0.95)),
    p99: round2(percentile(sorted, 0.99)),
    max: round2(sorted.at(-1) ?? 0),
    longTasks: tasks.length,
    longTaskMs: Math.round(tasks.reduce((sum, task) => sum + task.ms, 0)),
  };
}

const pageNow = (page: Page) => page.evaluate(() => performance.now());
const readBuffers = (page: Page) =>
  page.evaluate(() => {
    const w = window as unknown as Win;
    return { frames: [...w.__frames], long: [...w.__long], firstContentAt: w.__firstContentAt };
  });

type Ctx = {
  browser: Browser;
  url: (sessionId: string) => string;
  trace?: (name: string) => Promise<() => Promise<void>>;
};

async function openChat(ctx: Ctx, fixture: Fixture, status: string) {
  const events = [...fixture.log.events];
  served = {
    fixture,
    events,
    status,
    turnCount: events.filter((event) => event.kind === "user_message").length,
  };
  const start = (events.at(-1)?.at ?? Date.now()) + 60_000;
  const page = await ctx.browser.newPage({ viewport: { width: 900, height: 900 } });
  page.on("pageerror", (error) => console.log(`degenerate: ${fixture.name} page error: ${error.message}`));
  await page.addInitScript(instrument, start);
  await page.addInitScript(clockFollows, start);
  await installPaintedFrames(page);
  await page.addInitScript(recordFrames);
  return { page, start };
}

/// Waits for the chat's newest content to show (the fixture's latest reply, else any row).
async function contentShown(page: Page, fixture: Fixture) {
  await page.locator(".acpmux-scroll [data-row-id]").first().waitFor({ timeout: 120_000 });
  if (fixture.latest) await page.getByText(fixture.latest).first().waitFor({ timeout: 120_000 });
}

async function openScrollFling(ctx: Ctx, fixture: Fixture): Promise<Phase[]> {
  const phases: Phase[] = [];
  const stopOpen = await ctx.trace?.(`${fixture.name}-open`);
  const { page } = await openChat(ctx, fixture, "idle");
  try {
    await page.goto(ctx.url(fixture.log.sessionId));
    await contentShown(page, fixture);
    let buffers = await readBuffers(page);
    const first = buffers.firstContentAt ?? (await pageNow(page));
    // The 2 s after first content: wait them out, then read.
    const wait = first + OPEN_WINDOW_MS - (await pageNow(page));
    if (wait > 0) await page.waitForTimeout(wait + 50);
    await stopOpen?.();
    buffers = await readBuffers(page);
    phases.push({
      fixture: fixture.name,
      phase: "open",
      firstContentMs: Math.round(first),
      ...phaseStats(buffers.frames, buffers.long, first, first + OPEN_WINDOW_MS),
    });
    await rest(page);

    // scroll: wheel steps over the transcript, one per painted frame.
    const box = await page.locator(".acpmux-scroll").boundingBox();
    if (!box) throw new Error("no transcript to scroll");
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const stopScroll = await ctx.trace?.(`${fixture.name}-scroll`);
    const scrollFrom = await pageNow(page);
    const topBefore = await page.evaluate(() => document.querySelector(".acpmux-scroll")!.scrollTop);
    let atTop = 0;
    for (let step = 0; step < STEPS; step++) {
      await page.mouse.wheel(0, -WHEEL_PX);
      const top = await page.evaluate(async () => {
        await window.cmuxPaintFrame();
        return document.querySelector(".acpmux-scroll")!.scrollTop;
      });
      if (top <= 0) atTop += 1;
    }
    const scrollTo = await pageNow(page);
    await stopScroll?.();
    buffers = await readBuffers(page);
    const topAfter = await page.evaluate(() => document.querySelector(".acpmux-scroll")!.scrollTop);
    phases.push({
      fixture: fixture.name,
      phase: "scroll",
      ...phaseStats(buffers.frames, buffers.long, scrollFrom, scrollTo),
      note: `${STEPS} steps of ${WHEEL_PX} px, scrollTop ${Math.round(topBefore)} -> ${Math.round(topAfter)}${atTop ? `, ${atTop} steps at the top` : ""}`,
    });
    await rest(page);

    // fling: the pane's own debug fling, bottom to top of what is loaded.
    const stopFling = await ctx.trace?.(`${fixture.name}-fling`);
    const flingFrom = await pageNow(page);
    const fling = await page.evaluate(
      (seconds) =>
        (window as unknown as Win).cmuxAcpmuxDebug?.startFling(seconds, { wait: true, nominal_ms: 1000 / 60 }) ??
        Promise.resolve({ error: "no cmuxAcpmuxDebug" }),
      FLING_S,
    );
    const flingTo = await pageNow(page);
    await stopFling?.();
    buffers = await readBuffers(page);
    phases.push({
      fixture: fixture.name,
      phase: "fling",
      ...phaseStats(buffers.frames, buffers.long, flingFrom, flingTo),
      note: `${String(fling.distance_px ?? "?")} px over ${FLING_S} s, ${String(fling.viewports_per_frame ?? "?")} viewports/frame, ${String(fling.rows ?? "?")} rows${fling.error ? ` (${String(fling.error)})` : ""}`,
    });
  } finally {
    await page.close();
  }
  return phases;
}

async function streams(ctx: Ctx, fixture: Fixture): Promise<Phase[]> {
  const phases: Phase[] = [];
  const { page, start } = await openChat(ctx, fixture, "idle");
  const wallStart = Date.now();
  const clock = () => start + (Date.now() - wallStart);
  try {
    await page.goto(ctx.url(fixture.log.sessionId));
    await contentShown(page, fixture);
    for (let tries = 0; !served!.attached && tries < 600; tries++) await page.evaluate(() => window.cmuxPaintFrame());
    if (!served!.attached) throw new Error(`${fixture.name}: the pane never attached`);
    await rest(page);
    for (const [turn, tps] of TPS.entries()) {
      const name = `stream_${tps}tps${CHATS > 1 ? `_${CHATS}chats` : ""}`;
      emit({ mux: "user_message", msg: { text: `Degenerate turn ${turn}: stream ${tps} tokens a second` } }, clock());
      emit({ mux: "turn_started" }, clock());
      served!.turnCount += 1;
      statusChanged("running");
      for (const id of otherIds())
        broadcast("_acpmux/session_changed", {
          sessionId: id,
          session: otherSummary(id, served!, "running"),
          kind: "status",
        });
      await page.waitForTimeout(300);
      await rest(page);
      const words = tokens(9000 + turn, Math.ceil(tps * STREAM_S));
      const stop = await ctx.trace?.(`${fixture.name}-${name}`);
      const from = await pageNow(page);
      const began = performance.now();
      let sent = 0;
      while (sent < words.length) {
        const due = Math.min(words.length, Math.floor(((performance.now() - began) / 1000) * tps) + 1);
        for (; sent < due; sent++) {
          emit(
            { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: words[sent]! } } },
            clock(),
          );
          for (const id of otherIds()) {
            otherLastSeq.set(id, (otherLastSeq.get(id) ?? 12) + 1);
            broadcast("_acpmux/session_changed", {
              sessionId: id,
              session: otherSummary(id, served!, "running"),
              kind: "updated",
            });
          }
        }
        // fixed-wait: the wall-clock pacing of the stream itself.
        await Bun.sleep(2);
      }
      const seconds = (performance.now() - began) / 1000;
      const to = await pageNow(page);
      await stop?.();
      emit({ mux: "turn_result", msg: { status: "completed" } }, clock());
      statusChanged("idle");
      const buffers = await readBuffers(page);
      phases.push({
        fixture: fixture.name,
        phase: name,
        ...phaseStats(buffers.frames, buffers.long, from, to),
        note: `${words.length} tokens in ${seconds.toFixed(1)} s (${Math.round(words.length / seconds)} tok/s)`,
      });
      await rest(page);
    }
  } finally {
    await page.close();
  }
  return phases;
}

// ---------- the trace ----------
async function startTrace(cdp: CDPSession, file: string): Promise<() => Promise<void>> {
  await cdp.send("Tracing.start", {
    transferMode: "ReturnAsStream",
    traceConfig: { includedCategories: TRACE_CATEGORIES, excludedCategories: ["*"] },
  });
  return async () => {
    const done = new Promise<string>((resolve) =>
      cdp.once("Tracing.tracingComplete", (event: { stream?: string }) => resolve(event.stream!)),
    );
    await cdp.send("Tracing.end");
    const stream = await done;
    const out = fs.openSync(file, "w");
    try {
      for (;;) {
        const { data, eof, base64Encoded } = (await cdp.send("IO.read", { handle: stream, size: 1 << 20 })) as {
          data: string;
          eof: boolean;
          base64Encoded?: boolean;
        };
        if (base64Encoded) fs.writeSync(out, Buffer.from(data, "base64"));
        else fs.writeSync(out, data);
        if (eof) break;
      }
    } finally {
      fs.closeSync(out);
      await cdp.send("IO.close", { handle: stream });
    }
  };
}

type TraceEvent = { name: string; pid: number; id?: string; args?: { data?: Record<string, unknown> } };
type ProfileNode = {
  id: number;
  callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number };
};
/// Self time (ms) per function in a trace's V8 samples (ProfileChunk events), each sample charged the time to the
/// next one, keyed `name url:line:col` (pure).
export function traceSelfTimes(
  events: readonly TraceEvent[],
): Map<string, { ms: number; frame: ProfileNode["callFrame"] }> {
  const profiles = new Map<string, { nodes: Map<number, ProfileNode>; samples: number[]; deltas: number[] }>();
  for (const event of events) {
    if (event.name !== "ProfileChunk") continue;
    const key = `${event.pid}:${event.id}`;
    const profile = profiles.get(key) ?? {
      nodes: new Map<number, ProfileNode>(),
      samples: [] as number[],
      deltas: [] as number[],
    };
    profiles.set(key, profile);
    const data = event.args?.data as
      | { cpuProfile?: { nodes?: ProfileNode[]; samples?: number[] }; timeDeltas?: number[] }
      | undefined;
    for (const node of data?.cpuProfile?.nodes ?? []) profile.nodes.set(node.id, node);
    profile.samples.push(...(data?.cpuProfile?.samples ?? []));
    profile.deltas.push(...(data?.timeDeltas ?? []));
  }
  const self = new Map<string, { ms: number; frame: ProfileNode["callFrame"] }>();
  for (const profile of profiles.values())
    profile.samples.forEach((id, index) => {
      const frame = profile.nodes.get(id)?.callFrame;
      if (!frame || frame.functionName === "(idle)") return;
      const ms = (profile.deltas[index + 1] ?? 0) / 1000;
      const key = `${frame.functionName || "(anon)"} ${frame.url}:${frame.lineNumber}:${frame.columnNumber}`;
      const entry = self.get(key) ?? { ms: 0, frame };
      entry.ms += ms;
      self.set(key, entry);
    });
  return self;
}

function printHotspots(file: string, buildDir: string, top = 10) {
  const raw = JSON.parse(fs.readFileSync(file, "utf8")) as { traceEvents?: TraceEvent[] } | TraceEvent[];
  const events = Array.isArray(raw) ? raw : (raw.traceEvents ?? []);
  const mapper = sourceMapper(buildDir);
  const bySource = new Map<string, number>();
  for (const { ms, frame } of traceSelfTimes(events).values()) {
    const bundled = /\/assets\/[^/]+\.js$/.test(frame.url);
    const where = bundled
      ? mapper(frame.url.split("/").pop()!, frame.lineNumber, frame.columnNumber).replace(/^.*?webviews\//, "webviews/")
      : frame.url
        ? frame.url.split("/").pop()!
        : "";
    const key = bundled ? where : `${frame.functionName || "(anon)"}${where ? ` ${where}` : ""}`;
    bySource.set(key, (bySource.get(key) ?? 0) + ms);
  }
  const total = [...bySource.values()].reduce((sum, ms) => sum + ms, 0);
  console.log(`degenerate: ${path.basename(file)}: self time, ${total.toFixed(0)} ms sampled (not idle)`);
  for (const [key, ms] of [...bySource.entries()].sort((a, b) => b[1] - a[1]).slice(0, top))
    console.log(`    ${ms.toFixed(1).padStart(8)} ms  ${key}`);
}

// ---------- rows ----------
const rowFixture = (name: string) => name.toLowerCase().replace(/[^a-z0-9_]+/g, "_");
/// The perf rows of one phase (pure).
export function phaseRows(phase: Phase): PerfRow[] {
  const prefix = `degenerate.${phase.phase}.${rowFixture(phase.fixture)}`;
  const one = (metric: string, value: number, extra: Partial<PerfRow> = {}): PerfRow => ({
    name: `${prefix}.${metric}`,
    p50: value,
    p95: value,
    ...extra,
  });
  return [
    ...(phase.firstContentMs !== undefined
      ? [one("first_content_ms", phase.firstContentMs, { target: TARGET_MS.load, floor: 100 })]
      : []),
    one("interval_p50_ms", phase.p50, { floor: 2 }),
    one("interval_p95_ms", phase.p95, { floor: 4 }),
    one("interval_p99_ms", phase.p99, { floor: 8 }),
    one("interval_max_ms", phase.max, { floor: 16 }),
    one("long_tasks", phase.longTasks, { unit: "count", target: 0, floor: 1 }),
    one("long_task_ms", phase.longTaskMs, { floor: 50 }),
  ];
}
/// God against small, row by row, in quality-report.py --god-small's schema (pure).
export function godSmall(rows: readonly PerfRow[]): { name: string; small_p95: number; god_p95: number }[] {
  const by = new Map(rows.map((row) => [row.name, row.p95]));
  return rows.flatMap((row) => {
    const parts = row.name.split(".");
    if (parts[2] !== "small") return [];
    const god = by.get([...parts.slice(0, 2), "god", ...parts.slice(3)].join("."));
    return god === undefined
      ? []
      : [{ name: [...parts.slice(0, 2), ...parts.slice(3)].join("."), small_p95: row.p95, god_p95: god }];
  });
}

function table(phases: readonly Phase[]): string {
  const head =
    "| fixture | phase | first content ms | frames | FPS | p50 ms | p95 ms | p99 ms | max ms | long tasks | long task ms |";
  const lines = phases.map(
    (p) =>
      `| ${p.fixture} | ${p.phase} | ${p.firstContentMs ?? ""} | ${p.frames} | ${p.fps} | ${p.p50} | ${p.p95} | ${p.p99} | ${p.max} | ${p.longTasks} | ${p.longTaskMs} |`,
  );
  return [head, `|${"---|".repeat(11)}`, ...lines].join("\n");
}

if (import.meta.main) {
  const releases: (() => unknown)[] = [];
  const release = async () => {
    for (const stop of [...releases].reverse()) await Promise.resolve(stop()).catch(() => undefined);
  };
  process.once("SIGINT", () => void release().then(() => process.exit(130)));
  try {
    const fixtures: Fixture[] = [];
    for (const scale of SCALE ? [SCALE as Scale] : (["small", "god"] as Scale[])) {
      const madeAt = performance.now();
      const log = godLog(scale);
      fixtures.push({ name: scale, log, latest: LATEST_TEXT });
      console.log(
        `degenerate: ${scale}: ${log.events.length} records, ${rowsIn(log.events)} rows, made in ${((performance.now() - madeAt) / 1000).toFixed(1)} s`,
      );
    }
    for (const file of LOG_FILES) {
      const log = parseLog(path.basename(file), fs.readFileSync(file, "utf8"));
      checkSeq(log);
      fixtures.push({ name: rowFixture(path.basename(file).replace(/\.[^.]*$/, "")), log });
    }
    const daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
          if (served?.attached === ws) served.attached = undefined;
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.method === "_acpmux/attach" && served) served.attached = ws;
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "degenerate-chat-frames-"));
    releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const builtAt = performance.now();
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      // A source map (no change to the code that runs) so a trace maps back to webviews/src; one build for every
      // fixture, so god and small run the same code.
      build: { outDir: out, emptyOutDir: true, sourcemap: true },
      logLevel: "error",
    });
    console.log(`degenerate: pane built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
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
    const browserCdp = TRACE_DIR ? await browser.newBrowserCDPSession() : undefined;
    if (TRACE_DIR) fs.mkdirSync(TRACE_DIR, { recursive: true });
    const traced: string[] = [];
    const phases: Phase[] = [];
    let failed = 0;
    for (const fixture of fixtures) {
      const ctx: Ctx = {
        browser,
        url: (sessionId) =>
          `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${encodeURIComponent(sessionId)}`,
        ...(TRACE_DIR && browserCdp && fixture.name === "god"
          ? {
              trace: async (name: string) => {
                const file = path.join(TRACE_DIR, `${name}.json`);
                traced.push(file);
                return startTrace(browserCdp, file);
              },
            }
          : {}),
      };
      const startedAt = performance.now();
      try {
        phases.push(...(await openScrollFling(ctx, fixture)));
        phases.push(...(await streams(ctx, fixture)));
      } catch (error) {
        failed += 1;
        console.log(
          `degenerate: ${fixture.name} FAILED: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`,
        );
      }
      console.log(`degenerate: ${fixture.name} ran in ${((performance.now() - startedAt) / 1000).toFixed(0)} s`);
      for (const phase of phases.filter((p) => p.fixture === fixture.name && p.note))
        console.log(`  ${phase.phase}: ${phase.note}`);
    }
    const rows = phases.flatMap(phaseRows);
    for (const row of rows) perfRow(row);
    console.log(`\n${table(phases)}\n`);
    const pairs = godSmall(rows);
    if (OUT) {
      fs.writeFileSync(
        OUT,
        JSON.stringify(
          {
            bench: "degenerate-chat-frames",
            options: { tps: TPS, chats: CHATS, steps: STEPS, wheel_px: WHEEL_PX, fling_s: FLING_S, stream_s: STREAM_S },
            phases,
            perf_rows: rows,
            rows: pairs,
          },
          null,
          2,
        ) + "\n",
      );
      console.log(`degenerate: wrote ${OUT}`);
    }
    for (const file of traced) if (fs.existsSync(file)) printHotspots(file, out);
    if (failed) process.exitCode = 1;
  } finally {
    await release();
  }
}
