// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// A chat at any length costs what an empty one does (cmuxterm-hq goals/chats-flat-at-any-length.md: "A chat at 100k
// rows, and 20 such chats open, costs at most 1.2x an empty chat in renderer CPU (idle and streaming), RSS ..."). It
// opens the production pane (a vite build of the pane's dev entry) in Chromium with --process-per-site, as the app
// gives cmux-page one renderer, on a stand-in acpmux, in four launches of their own:
//   empty x1     one chat of one turn (the smallest chat that draws a reply);
//   long x1      one chat of ROWS transcript rows (ROWS/2 turns: a question and its answer each);
//   empty xN     N (CHATS, default 20) one-turn chats, the newest shown and the rest hidden;
//   long xN      N chats of ROWS rows each, the newest shown and the rest hidden;
//   grown x1/xN  one-turn chats that then take ROWS rows live while open (GROW_BATCH records a frame), as a chat that
//                ran for days in an open tab does: an opened long chat loads only its newest page, so it cannot show
//                what keeping every streamed record costs;
// and in each, once the pages settle:
//   idle         the renderers' CPU (/proc/PID/stat utime+stime) over IDLE_S seconds of nothing, as % of one core;
//   streaming    the same while the shown chat streams a turn of TPS chunks a second for STREAM_S seconds;
//   renderer MB  the renderers' proportional set size (/proc/PID/smaps_rollup Pss) after a collection on every page;
//   heap MB      the JS heap those pages use then (Runtime.getHeapUsage), its ratios beside ratio_max, not in it.
// Rows (PERF_ROW, chat_100k_flat.*): each value per launch, each long/empty ratio at x1 and xN, and ratio_max, the
// worst of the ratios a run measured (long and grown, each over empty; CASES below): the goal's number (NOW benches
// row chat_100k_flat_ratio_max, target 1.2, the worse of ratio_max and grown_many.ratio_max). A CPU ratio is
// taken over a floor of CPU_FLOOR_PCT (default 1 % of a core) on both sides, so two near-idle readings are not a ratio
// of noise.
// HIDDEN=0 keeps every chat shown. HEAP_SNAPSHOT=DIR writes each launch's V8 heap snapshots (the shown page, and in
// an xN launch a hidden one) for DevTools. HEAP_RETAINERS=1 prints, per launch, the renderers' memory-infra allocators
// and what holds the JS heap (heapRetainers.ts: the dominator tree, and self size by class over the empty launch).
// CASES=long runs only empty x1, long x1, empty xN and long xN. CASES=grown runs only empty x1 and grown x1.
// CASES=long-many runs only empty xN and long xN; with PROFILE it profiles every page of long xN. WAKES=1 also splits
// each idle window's renderer CPU by thread, so a burst on V8's worker threads reads apart from steady idle, and
// traces one hidden and the shown page of an xN launch. PROFILE=DIR writes CDP CPU profiles of the long x1 and grown x1 idle and streaming
// windows.
// WAKES=1 counts what wakes the renderers in each idle window, per second: the renderer threads' context switches
// (/proc/PID/task/*/status), and on every page the timer and interval callbacks, animation frames, MessagePort posts
// (React's scheduler) and DOM mutations. CASES=running runs only empty x1 and running x1, for an A/B of the running
// chat (bench/chat-running-idle-ab.sh).
// GROW_OPEN=1 grows the grown chats as one turn that never ends (a coordinator's: steers, replies and tool calls into a
// running turn, ten records a grown row pair, no turn_result), which a chat that sheds only at a turn's end never
// sheds (direct.ts `shedOlderHeld`, `midTurnCut`). For the case cmux#43436 left out.
// Resize (x1 launches, after the readings above; RESIZE=0 skips it): the shown chat's page takes RESIZE_WIDTHS one at
// a time, a second apart, as a window snapped or a divider let go does. Each width is new to the page, so the
// transcript lays out the whole chat at it. `resize ms` is the page's time from the width to the second frame after
// it; `resize cpu ms` is the renderer main thread's time over that second (the layout and the drawn rows' measures).
// The fixture's turns are plain prose (no code blocks), so the pane's highlighter, which runs on the main thread on an
// http: page and in a worker on cmux-page:, does no work here.
//   bun bench/chat-100k-flat.bench.ts [rows=100000] [chats=20]
// Linux only (it reads /proc).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ServerWebSocket } from "bun";
import type { CDPSession, Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { takeSnapshot } from "./heapProbe";
import { printRetainers, type Retainers } from "./heapRetainers";
import { describePaintWindow, paintWindow, runningAnimations } from "./paintWindow";
import { sourceMapper } from "./sourceMapper";
import { perfRow } from "./perfRow";
import { settledAt } from "./stability";

const ROWS = Number(process.argv[2] ?? 100_000);
const CHATS = Number(process.argv[3] ?? 20);
const IDLE_S = Number(process.env.IDLE_S ?? 10);
const STREAM_S = Number(process.env.STREAM_S ?? 10);
const TPS = Number(process.env.TPS ?? 30);
const CPU_FLOOR_PCT = Number(process.env.CPU_FLOOR_PCT ?? 1);
const HIDDEN = process.env.HIDDEN !== "0";
const PROFILE = process.env.PROFILE;
const GROW_BATCH = Number(process.env.GROW_BATCH ?? 400);
const REPEAT = Math.max(1, Number(process.env.REPEAT ?? 3));
const CASES = process.env.CASES ?? "all";
const RESIZE = process.env.RESIZE !== "0";
// Paint (x1 launches; PAINT=0 skips it): IDLE_S seconds of nothing with a turn open, one command in it still running
// and no record arriving (in empty x1 and long x1 a turn opened for it and closed after; running x1's own turn, a
// command started in it and finished after), read twice: the renderers' CPU, then a
// trace of what the shown page draws (paintWindow.ts: frames, main-thread frames and paints, the running animations
// and what each animates). A chat with a turn open moves only its running marks, on the compositor. Beside it, the
// same trace before the turn opens and while the open turn takes one reply chunk a second. Rows per window
// (idle_closed, idle_open, trickle_open): frames_per_s, main_frames_per_s, paints_per_s, main_ms_per_s, and
// idle_open_cpu_pct; none is in ratio_max.
const PAINT = process.env.PAINT !== "0";
const RESIZE_WIDTHS = [700, 620, 540, 460];
// CPU settle: once a launch's chats are loaded or grown, its renderers are sampled every second until two samples in
// a row are at most SETTLE_PCT of a core (a 1 s sample counts 10 ms ticks, so a 1 % threshold would be one tick of
// noise) or SETTLE_MAX_S pass. That time is the row cpu_settle_s, kept out of ratio_max, and the idle windows start
// after it: a burst's drain is read as a time, not folded into the idle CPU.
const SETTLE_PCT = Number(process.env.SETTLE_PCT ?? 2);
const SETTLE_MAX_S = Number(process.env.SETTLE_MAX_S ?? 60);
// A grown-many run's rows carry their own prefix: the perf cron stores them from a part of their own.
const ROW = CASES === "grown-many" ? "chat_100k_flat.grown_many" : "chat_100k_flat";
if (!["all", "main", "grown-many", "running", "long", "long-many", "grown"].includes(CASES)) {
  console.error("chat-100k-flat: CASES is all, main, grown-many, running, long, long-many or grown");
  process.exit(2);
}
const GROW_OPEN = process.env.GROW_OPEN === "1";
const HEAP_SNAPSHOT = process.env.HEAP_SNAPSHOT;
const HEAP_RETAINERS = process.env.HEAP_RETAINERS === "1";
const retainerBase = new Map<number, Retainers>();
const WAKES = process.env.WAKES === "1";
type Wakes = { timers: number; raf: number; posts: number; mutations: number };
if (!Number.isInteger(ROWS) || ROWS < 2 || !Number.isInteger(CHATS) || CHATS < 2) {
  console.error("usage: bun bench/chat-100k-flat.bench.ts [rows=100000] [chats=20]");
  process.exit(2);
}
if (process.platform !== "linux") {
  console.error("chat-100k-flat: Linux only (renderer CPU and memory from /proc)");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");
const TICK_HZ = 100; // USER_HZ, the unit of /proc/PID/stat utime and stime on Linux.

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Template = { events: Rec[]; session: Record<string, unknown>; turns: number };
const template = (turns: number): Template => {
  const { events, session } = papercutEvents({ turns, running: false });
  return { events: events as Rec[], session, turns };
};
const sessionId = (index: number) =>
  index === 0 ? PAPERCUT_CHAT : `0190b000-0000-7000-8000-${(0x200000 + index).toString(16).padStart(12, "0")}`;
// A page of records re-keyed from the template's chat to `id` (only what goes out is copied: one template per size).
const rekey = <T>(value: T, id: string): T =>
  id === PAPERCUT_CHAT ? value : JSON.parse(JSON.stringify(value).replaceAll(PAPERCUT_CHAT, id));

/// The renderer processes under `root` (a Chromium launch), by their command line.
function renderers(root: number): number[] {
  const children = new Map<number, number[]>();
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, "utf8");
      const parent = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      children.set(parent, [...(children.get(parent) ?? []), Number(entry)]);
    } catch {
      // Gone between the listing and the read.
    }
  }
  const out: number[] = [];
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      try {
        if (fs.readFileSync(`/proc/${child}/cmdline`, "utf8").includes("--type=renderer")) out.push(child);
      } catch {
        // Gone.
      }
      walk(child);
    }
  };
  walk(root);
  return out;
}
/// utime + stime of `pids` in clock ticks (a process gone since the listing counts nothing).
function cpuTicks(pids: number[]): number {
  let ticks = 0;
  for (const pid of pids) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      ticks += Number(fields[11]) + Number(fields[12]);
    } catch {
      // Gone.
    }
  }
  return ticks;
}
const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};
const pssMB = (pid: number) =>
  Number(/^Pss:\s+(\d+) kB/m.exec(fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"))?.[1] ?? 0) / 1024;

type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number } }[];
  samples?: number[];
  timeDeltas?: number[];
};
/// A CDP CPU profile's self time per site (function and source line, through the build's maps when there are any).
function selfTimes(cpu: CpuProfile, sources?: (file: string, line: number, column: number) => string) {
  const byId = new Map(cpu.nodes.map((node) => [node.id, node]));
  const out = new Map<string, number>();
  const samples = cpu.samples ?? [];
  const deltas = cpu.timeDeltas ?? [];
  for (let i = 0; i < samples.length; i++) {
    const frame = byId.get(samples[i]!)?.callFrame;
    if (!frame) continue;
    const file = frame.url.split("/").pop() ?? "";
    const where =
      frame.url && sources ? sources(file, frame.lineNumber, frame.columnNumber) : `${file}:${frame.lineNumber + 1}`;
    const site = `${frame.functionName || "(anonymous)"} ${frame.url ? where : ""}`.trim();
    out.set(site, (out.get(site) ?? 0) + (deltas[i + 1] ?? 0) / 1000);
  }
  return out;
}

type Launch = {
  name: string;
  idlePct: number;
  streamPct: number;
  mb: number;
  heapMb: number;
  renderers: number;
  settleS: number;
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of releases.splice(0).reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));

try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-100k-flat-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    // HEAP_RETAINERS: names as written, so a holder reads as its source's (the minified build's are two letters).
    build: { outDir: out, emptyOutDir: true, sourcemap: PAINT, ...(HEAP_RETAINERS ? { minify: false } : {}) },
    logLevel: "error",
  });
  // The paint windows name the sites that ask for frames by their source (the build's maps; PAINT above).
  const sources = PAINT ? sourceMapper(out) : undefined;
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      if (!(await file.exists())) return new Response("not found", { status: 404 });
      return new Response(file, { headers: pathname.endsWith(".css") ? { "cache-control": "max-age=3600" } : {} });
    },
  });
  releases.push(() => statics.stop(true));

  const small = template(1);
  const long = template(Math.floor(ROWS / 2));
  console.log(
    `chat-100k-flat: ${ROWS} rows (${long.turns} turns, ${long.events.length} records) vs 1 turn; x1 and x${CHATS}; ` +
      `idle ${IDLE_S}s, streaming ${STREAM_S}s at ${TPS}/s; ${HIDDEN ? "all but the newest chat hidden" : "every chat shown"}`,
  );

  const runLaunch = async (
    name: string,
    chat: Template,
    count: number,
    { profile, grow = 0, runGrow = 0 }: { profile?: string; grow?: number; runGrow?: number } = {},
  ): Promise<Launch> => {
    // The stand-in daemon for this launch: `count` chats of `chat`, and what streamed into each since.
    const sessions = Array.from({ length: count }, (_, index) => ({
      ...chat.session,
      sessionId: sessionId(index),
      title: `Chat ${index + 1}`,
      status: "ready",
    }));
    const streamed = new Map<string, Rec[]>();
    const sockets = new Map<string, ServerWebSocket<undefined>>();
    const recordsOf = (id: string) => {
      const extra = streamed.get(id);
      return extra?.length ? [...chat.events, ...extra] : chat.events;
    };
    const lastSeqOf = (id: string) => recordsOf(id).at(-1)?.seq ?? 0;
    const summaryOf = (id: string) => {
      const session = sessions.find((s) => s.sessionId === id) ?? sessions[0]!;
      return { ...session, lastSeq: lastSeqOf(id) };
    };
    const answer = (ws: ServerWebSocket<undefined>, method: string, params: Record<string, unknown>): unknown => {
      const id = String(params.sessionId ?? PAPERCUT_CHAT);
      switch (method) {
        case "initialize":
          return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
        case "_acpmux/watch":
          return { sessions: sessions.map((s) => summaryOf(s.sessionId)) };
        case "_acpmux/attach": {
          sockets.set(id, ws);
          const records = recordsOf(id);
          const { page, hasMore } = newestPage(records, {
            limit: Number(params.limit ?? 400),
            maxBytes: params.maxBytes,
          });
          return { session: summaryOf(id), lastSeq: lastSeqOf(id), events: rekey(page, id), hasMore };
        }
        case "_acpmux/events": {
          const records = recordsOf(id);
          if (params.promptIndex === true) {
            const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
            const prompts = records.filter((record) => record.kind === "user_message" && record.seq < before);
            return { events: rekey(prompts, id), hasMore: false, lastSeq: lastSeqOf(id) };
          }
          if (params.beforeSeq !== undefined) {
            const { page, hasMore } = newestPage(records, {
              limit: Number(params.limit ?? 400),
              beforeSeq: Number(params.beforeSeq),
              maxBytes: params.maxBytes,
            });
            return { events: rekey(page, id), hasMore, lastSeq: lastSeqOf(id) };
          }
          return { events: [], hasMore: false, lastSeq: lastSeqOf(id) };
        }
        default:
          return null;
      }
    };
    const daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id === undefined) return;
          ws.send(
            JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              result: answer(ws, message.method, message.params ?? {}),
            }),
          );
        },
      },
    });
    const notify = (id: string, method: string, params: unknown) =>
      sockets.get(id)?.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
    const emit = (id: string, dir: string, kind: string, msg: Record<string, unknown>) => {
      const list = streamed.get(id) ?? [];
      streamed.set(id, list);
      const record: Rec = { sessionId: id, seq: lastSeqOf(id) + 1, at: Date.now(), dir, kind, msg };
      list.push(record);
      notify(id, "_acpmux/event", record);
    };
    const setStatus = (id: string, status: string) => {
      const session = sessions.find((s) => s.sessionId === id)!;
      session.status = status;
      notify(id, "_acpmux/session_changed", {
        sessionId: id,
        session: summaryOf(id),
        kind: "status",
        seq: lastSeqOf(id),
      });
    };

    const server = await chromium.launchServer({
      headless: true,
      args: ["--process-per-site", "--js-flags=--expose-gc"],
    });
    const root = server.process().pid!;
    const browser = await chromium.connect(server.wsEndpoint());
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    if (WAKES)
      await context.addInitScript(() => {
        const wakes = { timers: 0, raf: 0, posts: 0, mutations: 0 };
        (globalThis as unknown as { __benchWakes: typeof wakes }).__benchWakes = wakes;
        type Callback = (...args: unknown[]) => unknown;
        const counted = (fn: unknown) =>
          typeof fn === "function"
            ? (...args: unknown[]) => {
                wakes.timers += 1;
                return (fn as Callback)(...args);
              }
            : fn;
        const timeout = globalThis.setTimeout;
        const interval = globalThis.setInterval;
        const frame = globalThis.requestAnimationFrame;
        const post = MessagePort.prototype.postMessage;
        globalThis.setTimeout = ((fn: unknown, ...rest: unknown[]) =>
          (timeout as Callback)(counted(fn), ...rest)) as typeof setTimeout;
        globalThis.setInterval = ((fn: unknown, ...rest: unknown[]) =>
          (interval as Callback)(counted(fn), ...rest)) as typeof setInterval;
        globalThis.requestAnimationFrame = (fn: FrameRequestCallback) =>
          frame((time) => {
            wakes.raf += 1;
            fn(time);
          });
        MessagePort.prototype.postMessage = function (this: MessagePort, ...args: unknown[]) {
          wakes.posts += 1;
          return (post as Callback).apply(this, args) as void;
        };
        new MutationObserver((records) => {
          wakes.mutations += records.length;
        }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      });
    try {
      const origin = `http://127.0.0.1:${statics.port}`;
      const urlFor = (index: number) =>
        `${origin}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId(index)}`;
      const firstText = `Answer ${chat.turns}:`;
      const pages: { page: Page; cdp: CDPSession }[] = [];
      for (let index = 0; index < count; index++) {
        const page = await context.newPage();
        await page.goto(urlFor(index));
        await page.waitForFunction((text) => document.body.textContent?.includes(text), firstText, {
          timeout: 180_000,
          polling: "raf",
        });
        pages.push({ page, cdp: await context.newCDPSession(page) });
      }
      if (runGrow > 0) {
        // Running: the newest chat starts one turn that never ends and takes `runGrow` cycles of a reply chunk, a tool
        // call and its completed update into it, GROW_BATCH records at a time, a frame apart: a coordinator's turn that
        // steers keep open for hours.
        const began = performance.now();
        const id = sessionId(count - 1);
        emit(id, "mux", "user_message", { text: "Coordinate the lanes" });
        emit(id, "mux", "turn_started", {});
        setStatus(id, "running");
        const update = (u: Record<string, unknown>) => ({
          method: "session/update",
          params: { sessionId: "agent-1", update: u },
        });
        for (let step = 1, batch = 0; step <= runGrow; step++) {
          emit(
            id,
            "in",
            "agent_message_chunk",
            update({
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `Running step ${step}: checking the lane. ` },
            }),
          );
          const call = `run-${step}`;
          emit(
            id,
            "in",
            "tool_call",
            update({
              sessionUpdate: "tool_call",
              toolCallId: call,
              title: `glaeda-gh status pr ${step}`,
              kind: "execute",
              status: "in_progress",
              rawInput: { command: `glaeda-gh status pr ${step}` },
            }),
          );
          emit(
            id,
            "in",
            "tool_call_update",
            update({
              sessionUpdate: "tool_call_update",
              toolCallId: call,
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: `checks SUCCESS: ${step} passed` } }],
            }),
          );
          batch += 3;
          if (batch >= GROW_BATCH) {
            batch = 0;
            // fixed-wait: one frame between batches, so the page applies them as it would a fast stream.
            await Bun.sleep(16);
          }
        }
        const lastText = `Running step ${runGrow}:`;
        await pages.at(-1)!.page.waitForFunction((text) => document.body.textContent?.includes(text), lastText, {
          timeout: 900_000,
          polling: 1000,
        });
        console.log(
          `  ${name}: ran ${runGrow} steps into one open turn in ${((performance.now() - began) / 1000).toFixed(1)} s`,
        );
      }
      if (grow > 0) {
        // Grown: each chat takes `grow` finished turns live, GROW_BATCH records at a time, a frame apart.
        const began = performance.now();
        for (let turn = 1, batch = 0; turn <= grow; turn++) {
          for (let index = 0; index < count && GROW_OPEN; index++) {
            const id = sessionId(index);
            const said = (sessionUpdate: string, fields: Record<string, unknown>) =>
              emit(id, "in", sessionUpdate, {
                method: "session/update",
                params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
              });
            if (turn === 1) {
              emit(id, "mux", "user_message", { text: "Grown question: coordinate the lanes" });
              emit(id, "mux", "turn_started", {});
            }
            emit(id, "mux", "user_message", { text: `Grown steer ${turn}`, steer: true });
            for (let chunk = 0; chunk < 7; chunk++)
              said("agent_message_chunk", {
                messageId: `grown-${turn}`,
                content: {
                  type: "text",
                  text: chunk === 0 ? `Grown answer ${turn}: ` : `the checks are green ${chunk}. `,
                },
              });
            said("tool_call", {
              toolCallId: `grown-call-${turn}`,
              kind: "execute",
              title: `check ${turn}`,
              status: "in_progress",
            });
            said("tool_call_update", {
              toolCallId: `grown-call-${turn}`,
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: `ok ${turn}` } }],
            });
            batch += 10;
          }
          for (let index = 0; index < count && !GROW_OPEN; index++) {
            const id = sessionId(index);
            emit(id, "mux", "user_message", { text: `Grown question ${turn}` });
            emit(id, "mux", "turn_started", {});
            emit(id, "in", "agent_message_chunk", {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: {
                  sessionUpdate: "agent_message_chunk",
                  content: { type: "text", text: `Grown answer ${turn}: the checks on the merged head are green.` },
                },
              },
            });
            emit(id, "mux", "turn_result", { status: "completed" });
            batch += 4;
          }
          if (batch >= GROW_BATCH) {
            batch = 0;
            // fixed-wait: one frame between batches, so the pages apply them as they would a fast stream.
            await Bun.sleep(16);
          }
        }
        const lastText = `Grown answer ${grow}:`;
        for (const { page } of pages)
          await page.waitForFunction((text) => document.body.textContent?.includes(text), lastText, {
            timeout: 900_000,
            polling: 1000,
          });
        console.log(
          `  ${name}: grew ${grow} turns a chat live in ${((performance.now() - began) / 1000).toFixed(1)} s`,
        );
      }
      const window = async (seconds: number, during?: () => Promise<void>) => {
        const pids = renderers(root);
        const from = cpuTicks(pids);
        const began = performance.now();
        if (during) await during();
        else await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
        const elapsed = (performance.now() - began) / 1000;
        return ((cpuTicks(pids) - from) / TICK_HZ / elapsed) * 100;
      };
      // The pages' own settling (read-ahead, fonts, the first paints, and after a burst its drain) is not idle: it is
      // timed from the last record in to the first of two quiet seconds.
      const settleFrom = performance.now();
      const settleSamples: number[] = [];
      let settleS = SETTLE_MAX_S;
      for (let quietSince = -1; (performance.now() - settleFrom) / 1000 < SETTLE_MAX_S;) {
        const sampleFrom = performance.now();
        const pct = await window(1);
        settleSamples.push(pct);
        if (pct > SETTLE_PCT) quietSince = -1;
        else if (quietSince < 0) quietSince = sampleFrom;
        else {
          settleS = (quietSince - settleFrom) / 1000;
          break;
        }
      }
      console.log(
        `  ${name}: CPU settled in ${settleS.toFixed(1)} s${settleS >= SETTLE_MAX_S ? " (cap)" : ""}; samples ${settleSamples.map((v) => v.toFixed(1)).join(", ")}`,
      );
      for (const { page } of pages) await settledAt(page).catch(() => undefined);
      if (HIDDEN) {
        // A chat tab that is not shown: its document turns hidden, as CEF's WasHidden makes it in the app. Only the
        // document's state is faked: Chromium still draws these pages (40 main frames a second each, in the trace
        // WAKES=1 takes), which the app's hidden pages do not. Minimizing each page's window does not hide it in
        // headless Chromium (tried: 0 of 19 turned hidden), so the hidden pages' frame cost is still unmeasured here.
        for (const { page } of pages.slice(0, -1))
          await page.evaluate(() => {
            Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
            Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
            document.dispatchEvent(new Event("visibilitychange"));
          });
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
      const shownProfiler = pages.at(-1)!.cdp;
      // Each reading is the median of REPEAT windows, so one noisy window on a shared runner cannot set the run's max
      // (single windows swung the worst ratio 3.1x to 15.8x between runs of the same commit). Only the first window of
      // each kind is profiled.
      const idleWindows: number[] = [];
      // WAKES=1: what woke the renderers in each idle window, per second (a sum over every page).
      const switches = () =>
        renderers(root).reduce((sum, pid) => {
          let tasks: string[] = [];
          try {
            tasks = fs.readdirSync(`/proc/${pid}/task`);
          } catch {
            return sum;
          }
          for (const task of tasks) {
            try {
              const status = fs.readFileSync(`/proc/${pid}/task/${task}/status`, "utf8");
              sum += Number(/^voluntary_ctxt_switches:\s+(\d+)/m.exec(status)?.[1] ?? 0);
              sum += Number(/^nonvoluntary_ctxt_switches:\s+(\d+)/m.exec(status)?.[1] ?? 0);
            } catch {
              // Gone.
            }
          }
          return sum;
        }, 0);
      const pageWakes = async (): Promise<Wakes> => {
        const total: Wakes = { timers: 0, raf: 0, posts: 0, mutations: 0 };
        for (const { page } of pages) {
          const one = await page.evaluate(
            () => (globalThis as unknown as { __benchWakes?: Wakes }).__benchWakes ?? null,
          );
          if (one) for (const key of Object.keys(total) as (keyof Wakes)[]) total[key] += one[key];
        }
        return total;
      };
      const idleWakes: (Wakes & { switches: number })[] = [];
      for (let round = 0; round < REPEAT; round++) {
        // A launch of many chats profiles every page (the hidden ones too), and names the sites that ran by their
        // source, summed over the pages.
        const profiled = profile && round === 0 ? (count > 1 ? pages.map((p) => p.cdp) : [shownProfiler]) : [];
        for (const cdp of profiled) {
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.start");
        }
        const wakesFrom = WAKES ? { ...(await pageWakes()), switches: switches() } : undefined;
        // WAKES=1: the renderers' CPU in the window by thread name (main, compositor, V8 workers, ...), so a cost that
        // is not JavaScript (GC helpers, raster, IPC) is named too.
        const threadTicks = () => {
          const out = new Map<string, number>();
          for (const pid of renderers(root)) {
            let tasks: string[] = [];
            try {
              tasks = fs.readdirSync(`/proc/${pid}/task`);
            } catch {
              continue;
            }
            for (const task of tasks) {
              try {
                const comm = fs.readFileSync(`/proc/${pid}/task/${task}/comm`, "utf8").trim().replace(/\d+$/, "");
                const stat = fs.readFileSync(`/proc/${pid}/task/${task}/stat`, "utf8");
                const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
                out.set(comm, (out.get(comm) ?? 0) + Number(fields[11]) + Number(fields[12]));
              } catch {
                // Gone.
              }
            }
          }
          return out;
        };
        const threadsFrom = WAKES ? threadTicks() : undefined;
        idleWindows.push(await window(IDLE_S));
        if (threadsFrom) {
          const to = threadTicks();
          const by = [...to]
            .map(([comm, ticks]) => [comm, ((ticks - (threadsFrom.get(comm) ?? 0)) / TICK_HZ / IDLE_S) * 100] as const)
            .filter(([, pct]) => pct > 0)
            .sort((a, b) => b[1] - a[1]);
          console.log(`  ${name}: idle cpu % by thread: ${by.map(([c, p]) => `${c} ${p.toFixed(1)}`).join(", ")}`);
        }
        if (wakesFrom) {
          const switchesTo = switches();
          const to = await pageWakes();
          idleWakes.push({
            switches: (switchesTo - wakesFrom.switches) / IDLE_S,
            timers: (to.timers - wakesFrom.timers) / IDLE_S,
            raf: (to.raf - wakesFrom.raf) / IDLE_S,
            posts: (to.posts - wakesFrom.posts) / IDLE_S,
            mutations: (to.mutations - wakesFrom.mutations) / IDLE_S,
          });
        }
        if (profiled.length) {
          fs.mkdirSync(profile!, { recursive: true });
          const self = new Map<string, number>();
          for (const [index, cdp] of profiled.entries()) {
            const { profile: cpu } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
            const file = profiled.length > 1 ? `${name}-idle-${index}.cpuprofile` : `${name}-idle.cpuprofile`;
            fs.writeFileSync(path.join(profile!, file), JSON.stringify(cpu));
            for (const [site, ms] of selfTimes(cpu, sources)) self.set(site, (self.get(site) ?? 0) + ms);
          }
          const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 25);
          console.log(`  ${name}: idle profile, self ms over ${profiled.length} page(s) in ${IDLE_S}s:`);
          for (const [site, ms] of top) console.log(`    ${ms.toFixed(1).padStart(8)} ms  ${site}`);
        }
      }
      // WAKES=1 in a launch of many chats: what each page draws while idle (a hidden one and the shown one traced),
      // and every page's running animations, so work a hidden or off-screen page still does is named.
      if (WAKES && count > 1) {
        for (const [index, { page }] of pages.entries()) {
          const running = await runningAnimations(page);
          if (running.length)
            console.log(
              `  ${name}: page ${index}${index === count - 1 ? " (shown)" : " (hidden)"} runs ${running.length} animation(s): ` +
                running
                  .slice(0, 6)
                  .map((a) => `${a.name} on ${a.target} [${a.properties.join(",")}]${a.onScreen ? "" : " off-screen"}`)
                  .join("; "),
            );
        }
        for (const index of [0, count - 1]) {
          const { page, cdp } = pages[index]!;
          const traced = await paintWindow(page, cdp, IDLE_S, sources);
          console.log(describePaintWindow(`${name} page ${index} idle`, traced));
        }
      }
      const idlePct = median(idleWindows);
      for (const [round, wakes] of idleWakes.entries())
        console.log(
          `  ${name}: idle window ${round + 1} ${idleWindows[round]!.toFixed(2)} % cpu; wakes/s: ` +
            `switches ${wakes.switches.toFixed(1)}, timers ${wakes.timers.toFixed(1)}, raf ${wakes.raf.toFixed(1)}, ` +
            `posts ${wakes.posts.toFixed(1)}, mutations ${wakes.mutations.toFixed(1)}`,
        );
      // Idle with a turn open (PAINT, above): the shown chat's running marks are all that may move.
      if (PAINT && count === 1) {
        const { page, cdp } = pages[0]!;
        const id = sessionId(0);
        // Each window's rows (`${window}_frames_per_s`, ...): numbers of their own, never in ratio_max.
        const rows = (prefix: string, paint: Awaited<ReturnType<typeof paintWindow>>) => {
          const row = (key: string, value: number, unit: string) =>
            perfRow({ name: `${ROW}.${name}.${prefix}_${key}`, p50: value, p95: value, unit });
          row("frames_per_s", paint.framesPerS, "count");
          row("main_frames_per_s", paint.mainFramesPerS, "count");
          row("paints_per_s", paint.paintsPerS, "count");
          row("main_ms_per_s", paint.taskMsPerS, "ms");
        };
        if (runGrow === 0) {
          const closed = await paintWindow(page, cdp, IDLE_S, sources);
          console.log(describePaintWindow(`${name} idle, no turn`, closed));
          rows("idle_closed", closed);
          emit(id, "mux", "user_message", { text: "Wait on the lanes" });
          emit(id, "mux", "turn_started", {});
          setStatus(id, "running");
        }
        // The open turn waits on one command that runs on (a coordinator's `glaeda-gh wait`), as the app's does.
        const said = (u: Record<string, unknown>) =>
          emit(id, "in", String(u.sessionUpdate), {
            method: "session/update",
            params: { sessionId: "agent-1", update: u },
          });
        said({
          sessionUpdate: "tool_call",
          toolCallId: "paint-wait",
          title: "glaeda-gh wait pr 1",
          kind: "execute",
          status: "in_progress",
          rawInput: { command: "glaeda-gh wait pr 1" },
        });
        // fixed-wait: the opened turn's marks mount and its records apply.
        await new Promise((resolve) => setTimeout(resolve, 2000));
        const openPct = await window(IDLE_S);
        const paint = await paintWindow(page, cdp, IDLE_S, sources);
        console.log(describePaintWindow(`${name} idle, turn open, ${openPct.toFixed(2)} % CPU`, paint));
        perfRow({ name: `${ROW}.${name}.idle_open_cpu_pct`, p50: openPct, p95: openPct, unit: "pct", clock: "cpu" });
        rows("idle_open", paint);
        // A trickle: the open turn takes one reply chunk a second (a coordinator's slow stream), so what one record
        // costs in frames and paints shows beside the window above.
        let trickling = true;
        const trickle = (async () => {
          for (let n = 0; trickling; n++) {
            said({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `still waiting ${n}. ` } });
            // fixed-wait: the trickle's own pacing.
            await new Promise((resolve) => setTimeout(resolve, 1000));
          }
        })();
        const trickled = await paintWindow(page, cdp, IDLE_S, sources);
        trickling = false;
        await trickle;
        console.log(describePaintWindow(`${name} turn open, a chunk a second`, trickled));
        rows("trickle_open", trickled);
        said({
          sessionUpdate: "tool_call_update",
          toolCallId: "paint-wait",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "green" } }],
        });
        if (runGrow === 0) {
          emit(id, "mux", "turn_result", { status: "completed" });
          setStatus(id, "ready");
        }
        // fixed-wait: the closed command's (and turn's) marks unmount before the streaming windows.
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      // Streaming: the shown chat (the newest) gets a reply of TPS chunks a second for STREAM_S seconds, REPEAT times.
      // In a running launch the reply goes into the open turn; otherwise each round is a turn of its own.
      const shown = sessionId(count - 1);
      const shownCdp = pages.at(-1)!.cdp;
      const streamWindows: number[] = [];
      let sent = 0;
      for (let round = 0; round < REPEAT; round++) {
        if (runGrow === 0) {
          emit(shown, "mux", "user_message", { text: `Stream a reply ${round + 1}` });
          emit(shown, "mux", "turn_started", {});
          setStatus(shown, "running");
          await new Promise((resolve) => setTimeout(resolve, 300));
        }
        if (profile && round === 0) {
          await shownCdp.send("Profiler.enable");
          await shownCdp.send("Profiler.start");
        }
        streamWindows.push(
          await window(STREAM_S, async () => {
            const began = performance.now();
            const total = sent + Math.ceil(TPS * STREAM_S);
            const from = sent;
            while (sent < total) {
              const due = Math.min(total, from + Math.floor(((performance.now() - began) / 1000) * TPS) + 1);
              for (; sent < due; sent++)
                emit(shown, "in", "agent_message_chunk", {
                  method: "session/update",
                  params: {
                    sessionId: "agent-1",
                    update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `word${sent} ` } },
                  },
                });
              // fixed-wait: the wall-clock pacing of the stream itself.
              await Bun.sleep(5);
            }
          }),
        );
        if (profile && round === 0) {
          const { profile: cpu } = (await shownCdp.send("Profiler.stop")) as { profile: unknown };
          fs.mkdirSync(profile, { recursive: true });
          const file = path.join(profile, `${name}-streaming.cpuprofile`);
          fs.writeFileSync(file, JSON.stringify(cpu));
          console.log(`chat-100k-flat: CPU profile of ${name} streaming: ${file}`);
        }
        if (runGrow === 0) {
          emit(shown, "mux", "turn_result", { status: "completed" });
          setStatus(shown, "ready");
          await new Promise((resolve) => setTimeout(resolve, 1000));
        }
      }
      const streamPct = median(streamWindows);
      console.log(
        `  ${name}: idle windows ${idleWindows.map((v) => v.toFixed(2)).join(", ")}; streaming ${streamWindows.map((v) => v.toFixed(2)).join(", ")}`,
      );
      await new Promise((resolve) => setTimeout(resolve, 1000));
      for (const { cdp } of pages) await cdp.send("HeapProfiler.collectGarbage");
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const pids = renderers(root);
      const mb = pids.reduce((sum, pid) => sum + pssMB(pid), 0);
      // heap MB: the JS heap the pages' one renderer uses after that collection (cmux-page's pages share an isolate,
      // so the shown page's reading is every page's), and its DOM.
      const shownPage = pages.at(-1)!;
      const { usedSize } = (await shownPage.cdp.send("Runtime.getHeapUsage")) as { usedSize: number };
      const heapMb = usedSize / 1048576;
      const elements = await shownPage.page.evaluate(() => document.getElementsByTagName("*").length);
      console.log(`  ${name}: JS heap ${heapMb.toFixed(1)} MB; shown page ${elements} elements`);
      if (HEAP_SNAPSHOT) {
        // HEAP_SNAPSHOT=DIR: the first page's (hidden in an xN launch) and the shown page's V8 heap, for DevTools.
        fs.mkdirSync(HEAP_SNAPSHOT, { recursive: true });
        const which =
          count > 1
            ? ([
                ["hidden", pages[0]!],
                ["shown", shownPage],
              ] as const)
            : ([["shown", shownPage]] as const);
        for (const [label, { cdp }] of which) {
          await cdp.send("HeapProfiler.enable");
          const chunks: string[] = [];
          const onChunk = (event: { chunk: string }) => chunks.push(event.chunk);
          cdp.on("HeapProfiler.addHeapSnapshotChunk", onChunk);
          await cdp.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false } as never);
          cdp.off("HeapProfiler.addHeapSnapshotChunk", onChunk);
          fs.writeFileSync(path.join(HEAP_SNAPSHOT, `${name}-${label}.heapsnapshot`), chunks.join(""));
        }
      }
      if (HEAP_RETAINERS) {
        // HEAP_RETAINERS=1: what holds the renderer's memory. Chromium's memory-infra dump of the renderers (V8, Blink's
        // GC heap, PartitionAlloc's partitions, malloc, caches), then the JS heap's dominator tree and self size by
        // class over the empty launch of the same count (heapRetainers.ts).
        try {
          const browserCdp = await browser.newBrowserCDPSession();
          const events: { ph?: string; pid?: number; args?: { dumps?: { allocators?: Record<string, unknown> } } }[] =
            [];
          browserCdp.on("Tracing.dataCollected", (event: { value: typeof events }) => events.push(...event.value));
          const complete = new Promise((resolve) => browserCdp.once("Tracing.tracingComplete", resolve));
          await browserCdp.send("Tracing.start", {
            traceConfig: {
              includedCategories: ["disabled-by-default-memory-infra"],
              memoryDumpConfig: { triggers: [] },
            },
            transferMode: "ReportEvents",
          } as never);
          await browserCdp.send("Tracing.requestMemoryDump", {
            deterministic: true,
            levelOfDetail: "detailed",
          } as never);
          await browserCdp.send("Tracing.end");
          await complete;
          const rendererPids = new Set(pids);
          for (const event of events) {
            const allocators = event.args?.dumps?.allocators as
              | Record<string, { attrs?: Record<string, { value?: string }> }>
              | undefined;
            if (event.ph !== "v" || !allocators || !rendererPids.has(event.pid!)) continue;
            const sizes = Object.entries(allocators)
              .map(([key, value]) => {
                const attr = value.attrs?.effective_size ?? value.attrs?.size;
                return [key, attr?.value ? parseInt(attr.value, 16) / 1048576 : 0] as const;
              })
              .filter(([key, size]) => key.split("/").length <= 3 && size >= 0.5 && !key.includes("0x"))
              .sort((a, b) => a[0].localeCompare(b[0]));
            console.log(`heap-retainers ${name}: renderer ${event.pid} allocators (MB):`);
            for (const [key, size] of sizes) console.log(`  ${size.toFixed(1).padStart(8)}  ${key}`);
          }
          await browserCdp.detach();
        } catch (error) {
          console.log(`heap-retainers ${name}: no memory-infra dump (${String(error).slice(0, 200)})`);
        }
        // Each React component on the shown page drawn from a `rows` list, with that list's length: the rows a view
        // holds, beside the rows its chat holds.
        const rowLists = await shownPage.page.evaluate(() => {
          const out: string[] = [];
          const seen = new Set<unknown>();
          type Fiber = { child?: Fiber; sibling?: Fiber; memoizedProps?: Record<string, unknown>; type?: unknown };
          const nameOf = (type: unknown): string =>
            typeof type === "function"
              ? (type as { displayName?: string; name?: string }).displayName || (type as { name: string }).name
              : typeof type === "object" && type !== null
                ? nameOf((type as { type?: unknown; render?: unknown }).type ?? (type as { render?: unknown }).render)
                : String(type);
          const roots = [document, ...document.querySelectorAll("body, body > *")];
          for (const node of roots) {
            const key = Object.keys(node).find(
              (k) => k.startsWith("__reactContainer$") || k.startsWith("__reactFiber$"),
            );
            if (!key) continue;
            const stack: Fiber[] = [(node as unknown as Record<string, Fiber>)[key]!];
            while (stack.length && out.length < 40) {
              const fiber = stack.pop()!;
              if (!fiber || seen.has(fiber)) continue;
              seen.add(fiber);
              for (const [prop, value] of Object.entries(fiber.memoizedProps ?? {}))
                if (Array.isArray(value) && value.length > 200 && !seen.has(value)) {
                  seen.add(value);
                  out.push(`${nameOf(fiber.type)}.${prop}=${value.length}`);
                }
              if (fiber.sibling) stack.push(fiber.sibling);
              if (fiber.child) stack.push(fiber.child);
            }
          }
          return out;
        });
        console.log(`heap-retainers ${name}: row lists ${rowLists.join(" ")}`);
        // Each Map or Set of at least 1000 entries a React component holds in a hook (a ref's `current`, a state, or a
        // field of an object one holds), by component and hook index: what a chat's view keeps that grows with it.
        const hookCollections = await shownPage.page.evaluate(() => {
          const out: string[] = [];
          const seen = new Set<unknown>();
          type Hook = { memoizedState?: unknown; next?: Hook | null };
          type Fiber = { child?: Fiber; sibling?: Fiber; memoizedState?: Hook | null; type?: unknown };
          const nameOf = (type: unknown): string =>
            typeof type === "function"
              ? (type as { displayName?: string; name?: string }).displayName || (type as { name: string }).name
              : typeof type === "object" && type !== null
                ? nameOf((type as { type?: unknown; render?: unknown }).type ?? (type as { render?: unknown }).render)
                : String(type);
          const look = (where: string, value: unknown, depth: number) => {
            if (value === null || typeof value !== "object" || seen.has(value) || depth > 2) return;
            seen.add(value);
            const size = value instanceof Map || value instanceof Set ? value.size : -1;
            if (size >= 1000) out.push(`${where}=${value.constructor.name}(${size})`);
            if (size >= 0 || Array.isArray(value) || value instanceof Node) return;
            for (const [key, field] of Object.entries(value)) look(`${where}.${key}`, field, depth + 1);
          };
          const roots = [document, ...document.querySelectorAll("body, body > *")];
          for (const node of roots) {
            const key = Object.keys(node).find(
              (k) => k.startsWith("__reactContainer$") || k.startsWith("__reactFiber$"),
            );
            if (!key) continue;
            const stack: Fiber[] = [(node as unknown as Record<string, Fiber>)[key]!];
            const fibers = new Set<Fiber>();
            while (stack.length) {
              const fiber = stack.pop()!;
              if (!fiber || fibers.has(fiber)) continue;
              fibers.add(fiber);
              if (typeof fiber.type === "function" || (typeof fiber.type === "object" && fiber.type !== null)) {
                let hook = fiber.memoizedState;
                for (let index = 0; hook && index < 400; index += 1, hook = hook.next)
                  look(`${nameOf(fiber.type)}#${index}`, hook.memoizedState, 0);
              }
              if (fiber.sibling) stack.push(fiber.sibling);
              if (fiber.child) stack.push(fiber.child);
            }
          }
          return out;
        });
        console.log(`heap-retainers ${name}: hook collections ${hookCollections.join(" ")}`);
        const domCounters = (await shownPage.cdp.send("Memory.getDOMCounters")) as Record<string, number>;
        console.log(`heap-retainers ${name}: shown page DOM counters ${JSON.stringify(domCounters)}`);
        const snapshot = await takeSnapshot(shownPage.cdp);
        const base = name.startsWith("empty") ? undefined : retainerBase.get(count);
        const summary = printRetainers(name, snapshot, base);
        if (name.startsWith("empty")) retainerBase.set(count, summary);
      }
      if (count === 1 && RESIZE) {
        const { page, cdp } = pages[0]!;
        await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
        const threadMs = async () => {
          const { metrics } = (await cdp.send("Performance.getMetrics")) as {
            metrics: { name: string; value: number }[];
          };
          return (metrics.find((metric) => metric.name === "ThreadTime")?.value ?? 0) * 1000;
        };
        const resizeMs: number[] = [];
        const resizeCpuMs: number[] = [];
        for (const width of RESIZE_WIDTHS) {
          const cpu = await threadMs();
          const from = await page.evaluate(() => performance.now());
          await page.setViewportSize({ width, height: 800 });
          const drawn = await page.evaluate(
            () =>
              new Promise<number>((resolve) =>
                requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now()))),
              ),
          );
          resizeMs.push(drawn - from);
          // fixed-wait: the window the CPU reading spans, so the drawn rows' measures after the width count too.
          await new Promise((resolve) => setTimeout(resolve, 1000));
          resizeCpuMs.push((await threadMs()) - cpu);
        }
        console.log(
          `  ${name}: resize ms ${resizeMs.map((v) => v.toFixed(0)).join(", ")} (median ${median(resizeMs).toFixed(0)}); ` +
            `resize cpu ms ${resizeCpuMs.map((v) => v.toFixed(0)).join(", ")} (median ${median(resizeCpuMs).toFixed(0)})`,
        );
      }
      const row: Launch = { name, idlePct, streamPct, mb, heapMb, renderers: pids.length, settleS };
      perfRow({ name: `${ROW}.${name}.cpu_settle_s`, p50: settleS, p95: settleS, unit: "s" });
      console.log(`${name} | ${row.renderers} | ${idlePct.toFixed(2)} | ${streamPct.toFixed(2)} | ${mb.toFixed(1)}`);
      perfRow({ name: `${ROW}.${name}.idle_cpu_pct`, p50: idlePct, p95: idlePct, unit: "pct", clock: "cpu" });
      perfRow({
        name: `${ROW}.${name}.stream_cpu_pct`,
        p50: streamPct,
        p95: streamPct,
        unit: "pct",
        clock: "cpu",
      });
      perfRow({ name: `${ROW}.${name}.renderer_mb`, p50: mb, p95: mb, unit: "MB" });
      perfRow({ name: `${ROW}.${name}.heap_mb`, p50: heapMb, p95: heapMb, unit: "MB" });
      return row;
    } finally {
      await context.close().catch(() => undefined);
      await server.close().catch(() => undefined);
      await daemon.stop(true);
    }
  };

  console.log("launch | renderers | idle CPU % | streaming CPU % | renderer MB");
  // CASES=main runs every case but grown xN; CASES=grown-many runs only empty xN and grown xN (20 chats taking 100k rows
  // each live takes about 28 minutes on a 4-vCPU runner, so the perf cron runs it as a part of its own); CASES=all
  // runs every case. The grown-many max is chat_100k_flat.grown_many.ratio_max, and the goal reads the worse of the two.
  const pairs: [string, Launch, Launch][] = [];
  if (CASES !== "grown-many" && CASES !== "long-many") {
    const emptyOne = await runLaunch("empty_x1", small, 1);
    if (CASES !== "running") {
      if (CASES !== "grown")
        pairs.push(["long_x1", await runLaunch("long_x1", long, 1, { profile: PROFILE }), emptyOne]);
      if (CASES !== "long") {
        const grownOne = await runLaunch("grown_x1", small, 1, { profile: PROFILE, grow: long.turns });
        pairs.push(["grown_x1", grownOne, emptyOne]);
      }
    }
    // Running: one chat whose single open turn takes about ROWS records live (a chunk, a tool call and its update per
    // step), the coordinator chat that never finishes its turn.
    if (CASES !== "long" && CASES !== "grown") {
      const runningOne = await runLaunch("running_x1", small, 1, { profile: PROFILE, runGrow: Math.ceil(ROWS / 3) });
      pairs.push(["running_x1", runningOne, emptyOne]);
    }
  }
  const emptyMany =
    CASES === "running" || CASES === "grown" ? undefined : await runLaunch(`empty_x${CHATS}`, small, CHATS);
  if (emptyMany && CASES !== "grown-many")
    pairs.push([`long_x${CHATS}`, await runLaunch(`long_x${CHATS}`, long, CHATS, { profile: PROFILE }), emptyMany]);
  if (emptyMany && CASES !== "main" && CASES !== "long" && CASES !== "long-many")
    pairs.push([`grown_x${CHATS}`, await runLaunch(`grown_x${CHATS}`, small, CHATS, { grow: long.turns }), emptyMany]);
  const cpuRatio = (a: number, b: number) => Math.max(a, CPU_FLOOR_PCT) / Math.max(b, CPU_FLOOR_PCT);
  const ratios: [string, number][] = [];
  for (const [label, big, base] of pairs) {
    ratios.push([`${label}.idle_cpu_ratio`, cpuRatio(big.idlePct, base.idlePct)]);
    ratios.push([`${label}.stream_cpu_ratio`, cpuRatio(big.streamPct, base.streamPct)]);
    ratios.push([`${label}.renderer_mb_ratio`, big.mb / base.mb]);
  }
  for (const [name, value] of ratios) {
    console.log(`chat-100k-flat: ${name} ${value.toFixed(2)}x`);
    perfRow({ name: `${ROW}.${name}`, p50: value, p95: value, unit: "x", target: 1.2, floor: 0.05 });
  }
  // The JS heap's long/empty ratios: where a renderer MB ratio comes from, read beside ratio_max, never in it.
  for (const [label, big, base] of pairs) {
    const value = big.heapMb / base.heapMb;
    console.log(`chat-100k-flat: ${label}.heap_mb_ratio ${value.toFixed(2)}x`);
    perfRow({ name: `${ROW}.${label}.heap_mb_ratio`, p50: value, p95: value, unit: "x" });
  }
  const [worst, max] = ratios.reduce((a, b) => (b[1] > a[1] ? b : a));
  console.log(`chat-100k-flat: worst ratio ${max.toFixed(2)}x (${worst}); target 1.2x`);
  const maxRow = `${ROW}.ratio_max`;
  perfRow({ name: maxRow, p50: max, p95: max, unit: "x", target: 1.2, floor: 0.05 });
  // The longest CPU settle of a long, grown or running launch, beside the empty launches' own: a number of its own,
  // read against its own target in the goal record, never in ratio_max.
  const [slowest, settleMax] = pairs
    .map(([label, big]) => [label, big.settleS] as [string, number])
    .reduce((a, b) => (b[1] > a[1] ? b : a));
  const emptySettle = Math.max(...pairs.map(([, , base]) => base.settleS));
  console.log(
    `chat-100k-flat: longest CPU settle ${settleMax.toFixed(1)} s (${slowest}); empty ${emptySettle.toFixed(1)} s`,
  );
  perfRow({ name: `${ROW}.cpu_settle_s_max`, p50: settleMax, p95: settleMax, unit: "s" });
  // What a long chat adds to the empty chats' own settle, the number the goal reads (target 2 s).
  const excess = Math.max(0, settleMax - emptySettle);
  perfRow({ name: `${ROW}.cpu_settle_excess_s`, p50: excess, p95: excess, unit: "s", target: 2 });
} finally {
  await release();
}
