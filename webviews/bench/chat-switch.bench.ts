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
// switch, so a slow arm shows what it asked for.
// LATENCY=ms delays every answer, as a remote or busy daemon does (a local one answers in about 1 ms):
// a switch that waits on several answers in turn shows it, one that draws from memory does not.
// Each arm's last round also measures 5 s of idle wakeups and renderer task time (bench/stability.ts).
//   bun bench/chat-switch.bench.ts [rounds=7] [turns=300]
// REMOTE_TAIL=both (or present/absent) switches to remote B before read-ahead, with A fast and
// PEER_ATTACH_MS=2000 delaying only B's live attach. This is a synthetic click-origin comparison,
// not a native Mac measurement. Each round starts a fresh page and ends after live reconciliation.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { perfRow, TARGET_MS } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, settledAt, type Idle } from "./stability";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(TURNS) || TURNS < 1) {
  console.error("usage: bun bench/chat-switch.bench.ts [rounds=7] [turns=300]");
  process.exit(2);
}
const LATENCY = Number(process.env.LATENCY ?? 0);
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
const FIRST_TEXT = `Answer ${TURNS}:`;
const SECOND_TEXT = `Reply ${TURNS}:`;

type Chat = {
  session: Record<string, unknown>;
  events: ReturnType<typeof papercutEvents>["events"];
};
const first = papercutEvents({ turns: TURNS, running: false });
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

/// Every protocol call the stand-in got, with its arrival (epoch ms) and chat.
let calls: { method: string; at: number; sessionId: string }[] = [];
/// The newest `limit` events of `chat` before `beforeSeq`, oldest first, and whether older ones remain.
const newest = (chat: Chat, limit: number, beforeSeq = Infinity) => {
  const older = chat.events.filter((event) => event.seq < beforeSeq);
  return { page: older.slice(-limit), hasMore: older.length > limit };
};
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
      const { page, hasMore } = newest(chat, Number(params.limit ?? 400));
      return { session: chat.session, lastSeq, events: page, hasMore };
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
        const { page, hasMore } = newest(chat, Number(params.limit ?? 400), Number(params.beforeSeq));
        return { events: page, hasMore, lastSeq };
      }
      return { events: [], hasMore: false, lastSeq };
    }
    default:
      return null;
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
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${A}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
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
  console.log(`chat-switch: ${TURNS} turns per chat, answers delayed ${LATENCY} ms, median of ${ROUNDS}`);
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
      perfRow({ name: `chat_switch.${key}.idle_cpu_ms`, p50: quiet.cpuMs, p95: quiet.cpuMs, target: 5, floor: 2 });
  }
} finally {
  await release();
}
