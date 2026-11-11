// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Switching to another chat inside the running pane: the production pane (a vite build of the pane's
// dev entry) joins a stand-in acpmux that holds two TURNS-turn chats, A and B. Each round loads A
// cold, waits until it is painted, then asks the pane to select B the way the host's
// sidebar does (`cmuxAcpmuxActions["chat.select"]`) and records, from that call (performance.now()):
//   latest     B's newest message ("Reply N:") painted;
//   settled    nothing moved for 400 ms after that: no long task or layout shift, and the scroller's
//              position and height unchanged;
//   long ms    long-task time from the call to settled, and the layout-shift sum over the same window.
// Two arms. `unread`: B is selected 150 ms after A paints, before the pane's idle read-ahead of the
// list's recent chats (direct.ts READ_AHEAD_DELAY_MS, 600 ms) has read it, so the switch waits on the
// daemon. `read ahead`: B is selected after 1.2 s of idle, once the read-ahead has kept B's newest
// page, so the switch draws it from memory. The stand-in lists the methods the pane sent for the
// switch, so a slow arm shows what it asked for. It pages as acpmux does, by count and by the ask's
// `maxBytes` (daemonPage.ts), and prints the size of B's attach page.
// PROFILE=1 builds the pane unminified and prints, for each arm's last switch, a CPU profile (self and
// inclusive time per function), the renderer's trace by event, and the DOM it left.
// LATENCY=ms delays every answer, as a remote or busy daemon does (a local one answers in about 1 ms):
// a switch that waits on several answers in turn shows it, one that draws from memory does not.
// Each arm's last round also measures 5 s of idle wakeups and renderer task time (bench/stability.ts).
// Then one page switches A and B back and forth (until warm, then CHURN=40 times) and prints what each switch leaves behind:
// chat_switch.churn.{heap_kb,dom_nodes,listeners}_per_switch, slopes after a forced GC whose target is 0 (bench/growth.ts).
//   bun bench/chat-switch.bench.ts [rounds=7] [turns=300]
// FIXTURE=god makes A and B god sessions (bench/godFixture.ts: tens of thousands of rows, MB tool outputs, nested
// subagents, images, months of history) instead of TURNS-turn chats, and names every row chat_switch.god.*: a row
// pairs with its ordinary twin by dropping `.god`.
// REMOTE_TAIL=both (or present/absent) switches to remote B before read-ahead, with A fast and
// PEER_ATTACH_MS=2000 delaying only B's live attach. This is a synthetic click-origin comparison,
// not a native Mac measurement. Each round starts a fresh page and ends after live reconciliation.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { newestPage } from "./daemonPage";
import { benchFixture, godChat, LATEST_TEXT, scaledPerfRow } from "./godFixture";
import { growthPerOp, growthRows, RESOLUTION, sampleGrowth, type GrowthSample } from "./growth";
import { diff as heapDiff, takeSnapshot, type Snapshot } from "./heapProbe";
import { perfRow as printRow, TARGET_MS } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, settledAt, type Idle } from "./stability";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(TURNS) || TURNS < 1) {
  console.error("usage: bun bench/chat-switch.bench.ts [rounds=7] [turns=300]");
  process.exit(2);
}
const FIXTURE = benchFixture();
const perfRow = scaledPerfRow(printRow, FIXTURE);
/// The growth phase: at least WARM switches to fill caches (at most MAX_WARM, see below), then CHURN switches
/// sampled every SAMPLE_EVERY.
const WARM = 6;
const MAX_WARM = Number(process.env.MAX_WARM ?? 400);
const CHURN = Number(process.env.CHURN ?? 40);
const SAMPLE_EVERY = 4;
const QUIET_MS = 1_000;
if (!Number.isInteger(CHURN) || CHURN <= 5 * SAMPLE_EVERY || CHURN % SAMPLE_EVERY)
  throw new Error(`CHURN must be a multiple of ${SAMPLE_EVERY} over ${5 * SAMPLE_EVERY}`);
const LATENCY = Number(process.env.LATENCY ?? 0);
const PROFILE = process.env.PROFILE === "1";
const REMOTE_TAIL = process.env.REMOTE_TAIL;
if (REMOTE_TAIL !== undefined && !["both", "present", "absent"].includes(REMOTE_TAIL))
  throw new Error("REMOTE_TAIL must be both, present, or absent");
const PEER_ATTACH_MS = REMOTE_TAIL ? Number(process.env.PEER_ATTACH_MS ?? 2000) : 0;
if (!Number.isFinite(PEER_ATTACH_MS) || PEER_ATTACH_MS < 0) throw new Error("PEER_ATTACH_MS must be non-negative");
type RemoteTail = "present" | "absent";
let remoteTail: RemoteTail | undefined;
const webviews = path.resolve(import.meta.dir, "..");
const A = PAPERCUT_CHAT;
const B = "0190a000-0000-7000-8000-00000000fc02";
const FIRST_TEXT = FIXTURE === "god" ? LATEST_TEXT : `Answer ${TURNS}:`;
const SECOND_TEXT = FIRST_TEXT.replace("Answer ", "Reply ");

type Chat = {
  session: Record<string, unknown>;
  events: ReturnType<typeof papercutEvents>["events"];
};
const first = FIXTURE === "god" ? godChat(A) : papercutEvents({ turns: TURNS, running: false });
const chats = new Map<string, Chat>([
  [A, { session: first.session, events: first.events.map((event) => ({ ...event, sessionId: A })) }],
  [
    B,
    {
      session: {
        ...first.session,
        sessionId: B,
        title: "Second chat",
        ...(REMOTE_TAIL ? { peer: "bench-vm", createdAt: 100 } : {}),
      },
      events: JSON.parse(JSON.stringify(first.events).replaceAll("Answer ", "Reply ")).map(
        (event: Chat["events"][number]) => ({ ...event, sessionId: B }),
      ),
    },
  ],
]);

/// B's last attach page: its records and its reply's JSON size.
let attachPage = { events: 0, bytes: 0 };
/// Every protocol call the stand-in got, with its arrival (epoch ms) and chat.
let calls: { method: string; at: number; sessionId: string }[] = [];
/// The newest page of `chat` before `beforeSeq`, as acpmux cuts it by count and by `maxBytes` (daemonPage.ts).
const newest = (chat: Chat, limit: number, beforeSeq = Infinity, maxBytes?: unknown) =>
  newestPage(chat.events, { limit, beforeSeq, maxBytes });
const peerSnapshot = () => {
  const chat = chats.get(B)!;
  const { page, hasMore } = newest(chat, 400);
  return {
    sessionId: B,
    qualifiedSessionId: `bench-vm/${B}`,
    peer: "bench-vm",
    generation: 100,
    capturedAt: Date.UTC(2026, 10, 3),
    stale: true,
    summary: chat.session,
    events: remoteTail === "present" ? page : [],
    hasMore: remoteTail === "present" && hasMore,
    lastSeq: remoteTail === "present" ? (chat.events.at(-1)?.seq ?? 0) : 0,
  };
};
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const chat = chats.get(String(params.sessionId)) ?? chats.get(A)!;
  const lastSeq = chat.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
      };
    case "_acpmux/peer_snapshot":
      return params.sessionId === B ? peerSnapshot() : null;
    case "_acpmux/watch":
      return { sessions: [...chats.values()].map((one) => one.session) };
    case "_acpmux/attach": {
      const { page, hasMore } = newest(chat, Number(params.limit ?? 400), Infinity, params.maxBytes);
      const result = { session: chat.session, lastSeq, events: page, hasMore };
      if (params.sessionId === B) attachPage = { events: page.length, bytes: JSON.stringify(result).length };
      return result;
    }
    case "_acpmux/events": {
      // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, each cut to its
      // text, in one reply.
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = chat.events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({
            ...event,
            msg: { text: String((event.msg as { text?: string }).text ?? "") },
          }));
        return { events: prompts, hasMore: false, lastSeq };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newest(chat, Number(params.limit ?? 400), Number(params.beforeSeq), params.maxBytes);
        return { events: page, hasMore, lastSeq };
      }
      return { events: [], hasMore: false, lastSeq };
    }
    default:
      return null;
  }
};

type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples: number[];
  timeDeltas: number[];
};
/// Self and inclusive (self plus callees, counted once per sample) time per function.
/// The source module of a line of an unminified bundle: the nearest `//#region` above it.
const regions = new Map<string, Promise<string[]>>();
const moduleAt = async (url: string, line: number) => {
  if (!url.startsWith("http")) return "";
  if (!regions.has(url))
    regions.set(
      url,
      fetch(url)
        .then((r) => r.text())
        .then(
          (t) => t.split("\n"),
          () => [],
        ),
    );
  const lines = await regions.get(url)!;
  for (let at = line; at >= 0; at -= 1) if (lines[at]?.startsWith("//#region ")) return lines[at]!.slice(10);
  return "";
};

const printProfile = async (profile: CpuProfile) => {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const where = new Map<string, string>();
  for (const node of profile.nodes) {
    const frame = node.callFrame;
    const key = `${frame.url}:${frame.lineNumber}`;
    if (!where.has(key)) where.set(key, await moduleAt(frame.url, frame.lineNumber));
  }
  const name = (id: number) => {
    const frame = byId.get(id)!.callFrame;
    const module = where.get(`${frame.url}:${frame.lineNumber}`) || frame.url.split("/").pop() || "";
    return `${frame.functionName || "(anon)"} ${module}:${frame.lineNumber + 1}`;
  };
  const self = new Map<string, number>();
  const total = new Map<string, number>();
  let busy = 0;
  profile.samples.forEach((id, index) => {
    const ms = (profile.timeDeltas[index] ?? 0) / 1000;
    if (byId.get(id)!.callFrame.functionName === "(idle)") return;
    busy += ms;
    self.set(name(id), (self.get(name(id)) ?? 0) + ms);
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) seen.add(name(at));
    for (const key of seen) total.set(key, (total.get(key) ?? 0) + ms);
  });
  const top = (map: Map<string, number>, count: number) =>
    [...map]
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key, ms]) => `  ${ms.toFixed(1)}\t${key}`);
  console.log(`profile: ${busy.toFixed(0)} ms busy; self time (ms)`);
  console.log(top(self, 40).join("\n"));
  console.log("profile: inclusive time (ms)");
  console.log(top(total, 70).join("\n"));
};

type TraceEvent = { name: string; ph: string; dur?: number; ts: number; tid: number; args?: any };
let traceEvents: TraceEvent[] = [];
/// The renderer main thread's work by event name, and its longest layouts and style recalcs.
const printTrace = (events: TraceEvent[]) => {
  const byName = new Map<string, number>();
  const complete = events.filter((event) => event.ph === "X" && event.dur);
  for (const event of complete) byName.set(event.name, (byName.get(event.name) ?? 0) + event.dur! / 1000);
  console.log("trace: total ms by event");
  for (const [name, ms] of [...byName].sort((a, b) => b[1] - a[1]).slice(0, 20))
    console.log(`  ${ms.toFixed(1)}\t${name}`);
  for (const name of ["Layout", "UpdateLayoutTree", "Paint", "RunTask", "FunctionCall"]) {
    const top = complete
      .filter((event) => event.name === name)
      .sort((a, b) => b.dur! - a.dur!)
      .slice(0, 6);
    for (const event of top)
      console.log(
        `  ${name} ${(event.dur! / 1000).toFixed(1)} ms ${JSON.stringify(event.args?.beginData ?? event.args?.data ?? event.args?.elementCount ?? {}).slice(0, 220)} ${JSON.stringify(event.args?.endData ?? "").slice(0, 120)}`,
      );
  }
};

const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));
try {
  const delayedReplies = new Set<ReturnType<typeof setTimeout>>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as {
          id?: number;
          method: string;
          params?: Record<string, unknown>;
        };
        calls.push({
          method: message.method,
          at: Date.now(),
          sessionId: String(message.params?.sessionId ?? ""),
        });
        if (message.id === undefined) return;
        const reply = JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: answer(message.method, message.params),
        });
        const delay =
          LATENCY + (message.method === "_acpmux/attach" && message.params?.sessionId === B ? PEER_ATTACH_MS : 0);
        if (delay > 0) {
          // fixed-wait: controlled peer latency; pending replies are cancelled when the daemon stops.
          const timer = setTimeout(() => {
            delayedReplies.delete(timer);
            ws.send(reply);
          }, delay);
          delayedReplies.add(timer);
        } else ws.send(reply);
      },
    },
  });
  releases.push([
    "stand-in acpmux",
    () => {
      for (const timer of delayedReplies) clearTimeout(timer);
      delayedReplies.clear();
      return daemon.stop(true);
    },
  ]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-switch-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, ...(PROFILE || process.env.HEAP_PROBE ? { minify: false } : {}) },
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
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${A}`;
  const launch = (args: string[] = []) =>
    chromium.launch({
      ...(process.env.CMUX_CHROME_HEADLESS_SHELL
        ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
        : { channel: "chrome" }),
      headless: true,
      args,
    });
  const browser = await launch();
  releases.push(["browser", () => browser.close()]);

  type Round = {
    latest: number;
    settled: number;
    longTasks: number;
    longMs: number;
    shift: number;
    sent: string[];
    quiet?: Idle;
    attach: number;
    reconciled: number;
    nativeReads: number;
    staleAtPaint: boolean;
    earlyTop: number;
    earlyHeight: number;
    finalTop: number;
    finalHeight: number;
    maxTopDrift: number;
    maxHeightDrift: number;
  };
  const open = async (idle: number, mode?: RemoteTail, still = false): Promise<Round> => {
    remoteTail = mode;
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    await addStabilityProbe(context, { boxes: false });
    const page = await context.newPage();
    const cdp = await cpuSession(page, true);
    if (mode)
      await page.addInitScript((sessionId) => {
        const timing = { attached: 0 };
        (window as unknown as { __remoteSwitch: typeof timing }).__remoteSwitch = timing;
        const Socket = window.WebSocket;
        window.WebSocket = class extends Socket {
          private attaches = new Set<string | number>();
          constructor(url: string | URL, protocols?: string | string[]) {
            super(url, protocols);
            this.addEventListener("message", (event) => {
              const reply = JSON.parse(String(event.data)) as {
                id?: string | number;
                result?: unknown;
              };
              if (reply.id !== undefined && this.attaches.delete(reply.id) && reply.result)
                timing.attached = performance.now();
            });
          }
          override send(data: Parameters<WebSocket["send"]>[0]): void {
            if (typeof data === "string") {
              const request = JSON.parse(data) as {
                id?: string | number;
                method?: string;
                params?: { sessionId?: string };
              };
              if (
                request.method === "_acpmux/attach" &&
                request.params?.sessionId === sessionId &&
                request.id !== undefined
              )
                this.attaches.add(request.id);
            }
            super.send(data);
          }
        } as typeof WebSocket;
      }, B);
    calls = [];
    try {
      await page.goto(url);
      await page.waitForFunction((text) => document.body.textContent?.includes(text), FIRST_TEXT, {
        timeout: 120_000,
        polling: 100,
      });
      // fixed-wait: the arm deliberately switches before or after the known idle read-ahead delay.
      await page.evaluate((idle) => new Promise<void>((resolve) => setTimeout(resolve, idle)), idle);
      if (
        mode &&
        calls.some((call) => call.sessionId === B && ["_acpmux/attach", "_acpmux/events"].includes(call.method))
      )
        throw new Error("remote B was read before the click; this round is not cold");
      calls = [];
      const profiling = PROFILE && still && cdp;
      if (profiling) {
        await profiling.send("Profiler.enable");
        await profiling.send("Profiler.setSamplingInterval", { interval: 100 });
        await profiling.send("Profiler.start");
        traceEvents = [];
        profiling.on("Tracing.dataCollected", (data) => {
          traceEvents.push(...(data.value as unknown as TraceEvent[]));
        });
        await profiling.send("Tracing.start", {
          categories: "devtools.timeline,disabled-by-default-devtools.timeline",
          transferMode: "ReportEvents",
        });
      }
      const got = await page.evaluate(
        ({ id, text, mode, snapshot }) =>
          new Promise<Omit<Round, "sent">>((resolve, reject) => {
            const state = {
              latest: 0,
              activity: 0,
              longTasks: 0,
              longMs: 0,
              shift: 0,
              top: -1,
              height: -1,
              reconciled: 0,
              nativeReads: 0,
              staleAtPaint: false,
              earlyTop: 0,
              earlyHeight: 0,
              finalTop: 0,
              finalHeight: 0,
              maxTopDrift: 0,
              maxHeightDrift: 0,
            };
            const actions = (
              window as unknown as {
                cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
              }
            ).cmuxAcpmuxActions;
            if (mode) {
              const before = actions["chat.tail.get"];
              actions["chat.tail.get"] = async (params) => {
                if (params.sessionId !== id) return before?.(params) ?? null;
                state.nativeReads += 1;
                return snapshot;
              };
            }
            const attached = () =>
              mode ? (window as unknown as { __remoteSwitch: { attached: number } }).__remoteSwitch.attached : 0;
            const visible = () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              if (!scroller) return false;
              const viewport = scroller.getBoundingClientRect();
              return [...scroller.querySelectorAll<HTMLElement>("[data-row-id]")].some((row) => {
                if (!row.textContent?.includes(text)) return false;
                const box = row.getBoundingClientRect();
                return box.bottom > viewport.top && box.top < viewport.bottom && box.height > 0;
              });
            };
            let frame = 0;
            const paintTimers = new Set<ReturnType<typeof setTimeout>>();
            const afterPaint = (done: () => void) => {
              const timer = setTimeout(() => {
                paintTimers.delete(timer);
                done();
              }, 0);
              paintTimers.add(timer);
            };
            const cleanup = () => {
              cancelAnimationFrame(frame);
              for (const timer of paintTimers) clearTimeout(timer);
              longObserver.disconnect();
              shiftObserver.disconnect();
            };
            // Origin is the same host selection call as a sidebar click; setup above is excluded.
            const t0 = performance.now();
            state.activity = t0;
            const longObserver = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                if (entry.startTime < t0) continue;
                state.longTasks += 1;
                state.longMs += entry.duration;
                state.activity = Math.max(state.activity, entry.startTime + entry.duration);
              }
            });
            longObserver.observe({ type: "longtask" });
            const shiftObserver = new PerformanceObserver((list) => {
              for (const entry of list.getEntries() as unknown as {
                value: number;
                hadRecentInput: boolean;
                startTime: number;
              }[]) {
                if (entry.hadRecentInput || entry.startTime < t0) continue;
                state.shift += entry.value;
                state.activity = Math.max(state.activity, entry.startTime);
              }
            });
            shiftObserver.observe({ type: "layout-shift" });
            const tick = () => {
              const now = performance.now();
              if (!state.latest && visible())
                afterPaint(() => {
                  if (state.latest || !visible()) return;
                  state.latest = performance.now();
                  const scroll = document.querySelector<HTMLElement>(".acpmux-scroll");
                  state.earlyTop = scroll?.scrollTop ?? 0;
                  state.earlyHeight = scroll?.scrollHeight ?? 0;
                  state.staleAtPaint = !!document.querySelector(".acpmux-peer-copy");
                });
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              const top = scroller?.scrollTop ?? -1;
              const height = scroller?.scrollHeight ?? -1;
              if (top !== state.top || height !== state.height) {
                state.top = top;
                state.height = height;
                state.activity = Math.max(state.activity, now);
              }
              if (state.latest && scroller) {
                state.finalTop = top;
                state.finalHeight = height;
                state.maxTopDrift = Math.max(state.maxTopDrift, Math.abs(top - state.earlyTop));
                state.maxHeightDrift = Math.max(state.maxHeightDrift, Math.abs(height - state.earlyHeight));
                if (
                  mode &&
                  !state.reconciled &&
                  attached() > t0 &&
                  !document.querySelector(".acpmux-peer-copy") &&
                  visible()
                )
                  afterPaint(() => (state.reconciled ||= performance.now()));
              }
              if (
                state.latest &&
                (!mode || state.reconciled) &&
                now - Math.max(state.latest, state.activity, state.reconciled) > 400
              ) {
                cleanup();
                if (mode && scroller?.textContent?.split(text).length !== 2) {
                  reject(new Error("reconciled B must render its newest marker exactly once"));
                  return;
                }
                resolve({
                  latest: state.latest - t0,
                  settled: Math.max(state.latest, state.activity, state.reconciled) - t0,
                  longTasks: state.longTasks,
                  longMs: state.longMs,
                  shift: state.shift,
                  attach: attached() ? attached() - t0 : 0,
                  reconciled: state.reconciled ? state.reconciled - t0 : 0,
                  nativeReads: state.nativeReads,
                  staleAtPaint: state.staleAtPaint,
                  earlyTop: state.earlyTop,
                  earlyHeight: state.earlyHeight,
                  finalTop: state.finalTop,
                  finalHeight: state.finalHeight,
                  maxTopDrift: state.maxTopDrift,
                  maxHeightDrift: state.maxHeightDrift,
                });
                return;
              }
              if (now - t0 > 60_000) {
                cleanup();
                reject(new Error(`${text} never painted and reconciled`));
                return;
              }
              frame = requestAnimationFrame(tick);
            };
            void actions["chat.select"]!({ sessionId: id }).catch((error: unknown) => {
              cleanup();
              reject(error);
            });
            frame = requestAnimationFrame(tick);
          }),
        { id: B, text: SECOND_TEXT, mode, snapshot: peerSnapshot() },
      );
      if (profiling) {
        const done = new Promise<void>((resolve) => profiling.once("Tracing.tracingComplete", () => resolve()));
        await profiling.send("Tracing.end");
        await done;
        printTrace(traceEvents);
        await printProfile((await profiling.send("Profiler.stop")).profile as CpuProfile);
        console.log(
          "dom:",
          JSON.stringify(
            await page.evaluate(() => ({
              elements: document.querySelectorAll("*").length,
              rows: document.querySelectorAll("[data-row-id]").length,
              railTicks: document.querySelectorAll(".acpmux-minimap *").length,
              summary: document.querySelectorAll(".acpmux-summary-card *").length,
              // The summary column's elements by section (its title), and outside any section.
              summaryBy: Object.fromEntries(
                [...document.querySelectorAll(".acpmux-summary-card .acpmux-summary-section")].map((section) => [
                  section.getAttribute("aria-label") ?? "?",
                  section.querySelectorAll("*").length,
                ]),
              ),
              transcript: document.querySelectorAll(".acpmux-scroll *").length,
            })),
          ),
        );
      }
      const sent = calls.map((call) => `${call.method}${call.sessionId === B ? " (B)" : ""}`);
      let quiet: Idle | undefined;
      if (still) {
        await settledAt(page);
        [quiet] = await measureIdle([{ page, cdp }]);
      }
      return { ...got, sent, ...(quiet ? { quiet } : {}) };
    } finally {
      await context.close();
    }
  };

  const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
  console.log(
    `chat-switch: ${FIXTURE === "god" ? "god sessions" : `${TURNS} turns per chat`}, answers delayed ${LATENCY} ms, median of ${ROUNDS}`,
  );
  console.log("arm | latest ms | settled ms | long tasks | long ms | layout shift");
  const arms: { name: string; idle: number; mode?: RemoteTail }[] = REMOTE_TAIL
    ? (REMOTE_TAIL === "both" ? (["absent", "present"] as const) : [REMOTE_TAIL as RemoteTail]).map((mode) => ({
        name: `remote ${mode}`,
        idle: 150,
        mode,
      }))
    : [
        { name: "unread", idle: 150 },
        { name: "read ahead", idle: 1200 },
      ];
  if (REMOTE_TAIL)
    console.log(
      `synthetic click-origin remote arms; B attach delayed ${PEER_ATTACH_MS} ms; no native Mac latency claim`,
    );
  for (const { name: arm, idle, mode } of arms) {
    await open(idle, mode); // warm the server and the browser process
    const rounds: Round[] = [];
    for (let round = 0; round < ROUNDS; round++) rounds.push(await open(idle, mode, round === ROUNDS - 1));
    const of = (pick: (r: Round) => number) => median(rounds.map(pick));
    console.log(
      [
        arm,
        of((r) => r.latest).toFixed(0),
        of((r) => r.settled).toFixed(0),
        of((r) => r.longTasks).toFixed(0),
        of((r) => r.longMs).toFixed(0),
        of((r) => r.shift).toFixed(4),
      ].join(" | "),
    );
    console.log(`  the pane sent for the switch: ${rounds.at(-1)!.sent.join(", ") || "nothing"}`);
    console.log(`  B's attach page: ${attachPage.events} records, ${(attachPage.bytes / 1024).toFixed(0)} KiB`);
    if (mode) {
      console.log(
        "  attach ms | reconciled paint ms | first paint before attach | stale at first paint | native reads | max scrollTop drift px | max scrollHeight drift px | early scrollTop px | early scrollHeight px | final scrollTop px | final scrollHeight px",
      );
      console.log(
        [
          of((r) => r.attach).toFixed(1),
          of((r) => r.reconciled).toFixed(1),
          rounds.every((r) => r.latest < r.attach),
          rounds.every((r) => r.staleAtPaint),
          of((r) => r.nativeReads),
          of((r) => r.maxTopDrift).toFixed(1),
          of((r) => r.maxHeightDrift).toFixed(1),
          of((r) => r.earlyTop).toFixed(1),
          of((r) => r.earlyHeight).toFixed(1),
          of((r) => r.finalTop).toFixed(1),
          of((r) => r.finalHeight).toFixed(1),
        ].join(" | "),
      );
      for (const [metric, pick, unit] of [
        ["attach", (r: Round) => r.attach, "ms"],
        ["reconciled", (r: Round) => r.reconciled, "ms"],
        ["scroll_top_drift", (r: Round) => r.maxTopDrift, "px"],
        ["scroll_height_drift", (r: Round) => r.maxHeightDrift, "px"],
        ["layout_shift", (r: Round) => r.shift, "score"],
      ] as const)
        perfRow({
          name: `chat_switch.remote_${mode}.${metric}`,
          p50: of(pick),
          p95: of(pick),
          unit,
        });
    }
    // The median of rounds, as both p50 and p95 (perfRow.ts); from the select call.
    const key = arm.replace(" ", "_");
    perfRow({
      name: `chat_switch.${key}.latest`,
      p50: of((r) => r.latest),
      p95: of((r) => r.latest),
      target: TARGET_MS.response,
    });
    perfRow({
      name: `chat_switch.${key}.settled`,
      p50: of((r) => r.settled),
      p95: of((r) => r.settled),
    });
    perfRow({
      name: `chat_switch.${key}.long_ms`,
      p50: of((r) => r.longMs),
      p95: of((r) => r.longMs),
    });
    // Stability (bench/stability.ts): no shift, and a chat at rest wakes nothing.
    const cls = Math.round(of((r) => r.shift) * 1e4) / 1e4;
    perfRow({ name: `chat_switch.${key}.cls`, p50: cls, p95: cls, unit: "score", target: 0, floor: 0.001 });
    const quiet = rounds.at(-1)!.quiet!;
    console.log(
      `  at rest for 5 s: ${quiet.wakeups} wakeups, ${quiet.cpuMs?.toFixed(1) ?? "-"} ms of renderer tasks` +
        (quiet.sources.length ? `; ${quiet.sources.slice(0, 12).join("; ")}` : ""),
    );
    perfRow({
      name: `chat_switch.${key}.idle_wakeups`,
      p50: quiet.wakeups,
      p95: quiet.wakeups,
      unit: "count",
      target: 0,
      floor: 0.5,
    });
    if (quiet.cpuMs !== null)
      perfRow({
        name: `chat_switch.${key}.idle_cpu_ms`,
        p50: quiet.cpuMs,
        p95: quiet.cpuMs,
        target: 5,
        floor: 2,
        clock: "cpu",
        version: 3,
      });
  }
  // Growth per switch (bench/growth.ts): one page switches A, B, A, B... and, once warm, samples the GC'd heap, DOM
  // nodes and listeners every SAMPLE_EVERY of CHURN switches. Back where it started, a switch must leave nothing
  // behind: each slope's target is 0. Warm is WARM switches and then as many as the wire log (wire.ts, the inspector's
  // bounded record of every message) needs to turn over: until every entry it keeps is a switch's, it grows by
  // design toward its bound, and that fill is not a leak (test/wire-log-bounds.test.ts holds the bound).
  // Three heap snapshots in the churn (bench/heapProbe.ts) give chat_switch.churn.external_kb_per_switch: the
  // external strings (socket frames) that piled up, which the heap usage above does not count. HEAP_PROBE=1 prints
  // everything that piled up, by constructor and by the oldest object holding it, from an unminified build.
  if (!REMOTE_TAIL) {
    // Its own browser with V8's JIT off: compiled code grows in steps as hot functions tier up (about 30 KB a switch
    // over 120 switches, and slowing), which is the engine warming, not the page keeping anything. Without it
    // the GC'd heap is flat to within a few KB (2026-11-10, both fixtures), so a slope is what the page keeps.
    const growthBrowser = await launch(["--js-flags=--jitless"]);
    releases.push(["growth browser", () => growthBrowser.close()]);
    const context = await growthBrowser.newContext({ viewport: { width: 1200, height: 800 } });
    try {
      const page = await context.newPage();
      const cdp = await context.newCDPSession(page);
      await page.goto(url);
      await page.waitForFunction((text) => document.body.textContent?.includes(text), FIRST_TEXT, {
        timeout: 120_000,
        polling: 100,
      });
      let op = 0;
      const switchOnce = async () => {
        op += 1;
        const [id, text, other] = op % 2 ? [B, SECOND_TEXT, FIRST_TEXT] : [A, FIRST_TEXT, SECOND_TEXT];
        await page.evaluate(
          (id) =>
            (
              window as unknown as {
                cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
              }
            ).cmuxAcpmuxActions["chat.select"]!({ sessionId: id }),
          id,
        );
        await page.waitForFunction(
          ({ text, other }) => {
            const scroller = document.querySelector(".acpmux-scroll");
            return !!scroller?.textContent?.includes(text) && !scroller.textContent.includes(other);
          },
          { text, other },
          { timeout: 60_000, polling: "raf" },
        );
      };
      const wireLog = () =>
        page.evaluate(() => {
          const debug = (
            window as unknown as {
              cmuxAcpmuxDebug?: {
                acpLog(options: { limit: number }): { stats: { oldestSeq?: number }; entries: { seq: number }[] };
              };
            }
          ).cmuxAcpmuxDebug;
          if (!debug) throw new Error("the pane has no cmuxAcpmuxDebug");
          const log = debug.acpLog({ limit: 1 });
          return { oldest: log.stats.oldestSeq ?? 0, newest: log.entries[0]?.seq ?? 0 };
        });
      // A sample waits until the stand-in has had no call for QUIET_MS, longer than the idle read-ahead delay: a
      // god chat's older pages and the read-ahead land after its newest page paints, and a sample taken while
      // they arrive measures where the load is, not what the switch kept.
      const standInQuiet = async () => {
        const deadline = Date.now() + 30_000;
        for (let quietFor = 0; quietFor < QUIET_MS && Date.now() < deadline;) {
          // fixed-wait: waits out the stand-in's last call, re-armed by each new one, to a deadline.
          await Bun.sleep(QUIET_MS - quietFor);
          quietFor = Date.now() - (calls.at(-1)?.at ?? 0);
        }
      };
      while (op < WARM) await switchOnce();
      // Turned over: the oldest entry kept was logged after the first WARM switches, so the log holds only
      // switches' messages and each new one replaces an old one.
      const { newest: warmedAt } = await wireLog();
      while (op % 2 || ((await wireLog()).oldest <= warmedAt && op < MAX_WARM)) await switchOnce();
      const warm = op;
      if ((await wireLog()).oldest <= warmedAt)
        throw new Error(`the wire log did not turn over in ${MAX_WARM} switches`);
      const snapshots: Snapshot[] = [];
      const samples: GrowthSample[] = [];
      // Early, middle and late, each with A selected: what was made early to middle and is alive late piled up.
      const snapshotAt = [SAMPLE_EVERY, 5 * SAMPLE_EVERY, CHURN];
      while (op < warm + CHURN) {
        await switchOnce();
        if ((op - warm) % SAMPLE_EVERY) continue;
        await standInQuiet();
        samples.push(await sampleGrowth(cdp, op));
        if (snapshotAt.includes(op - warm)) snapshots.push(await takeSnapshot(cdp));
      }
      const [early, middle, late] = snapshots;
      const { externalBytes } = heapDiff(early!, late!, FIXTURE, middle, !!process.env.HEAP_PROBE);
      const externalKb = externalBytes / 1024 / (snapshotAt[1]! - snapshotAt[0]!);
      console.log(`growth: ${warm} warm switches (the wire log turned over), then ${CHURN} sampled`);
      console.log(`SAMPLES ${samples.map((sample) => Math.round(sample.heapKb)).join(" ")}`);
      const growth = growthPerOp(samples);
      console.log(
        `growth over ${CHURN} switches: heap ${growth.heapKbPerOp} KB, ${growth.nodesPerOp} DOM nodes, ` +
          `${growth.listenersPerOp} listeners per switch (first sample ${JSON.stringify(samples[0])}, last ${JSON.stringify(samples.at(-1))})`,
      );
      for (const row of growthRows("chat_switch.churn", "switch", growth)) perfRow(row);
      console.log(`external strings kept: ${Math.round(externalKb * 100) / 100} KB per switch`);
      perfRow({
        name: "chat_switch.churn.external_kb_per_switch",
        p50: externalKb > RESOLUTION.heapKbPerOp ? Math.round(externalKb * 100) / 100 : 0,
        p95: externalKb > RESOLUTION.heapKbPerOp ? Math.round(externalKb * 100) / 100 : 0,
        unit: "KB",
        target: 0,
        floor: RESOLUTION.heapKbPerOp,
        clock: "cpu",
      });
    } finally {
      await context.close();
    }
  }
} finally {
  await release();
}
