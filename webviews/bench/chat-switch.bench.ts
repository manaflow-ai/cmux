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
//   bun bench/chat-switch.bench.ts [rounds=7] [turns=300]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(TURNS) || TURNS < 1) {
  console.error("usage: bun bench/chat-switch.bench.ts [rounds=7] [turns=300]");
  process.exit(2);
}
const LATENCY = Number(process.env.LATENCY ?? 0);
const webviews = path.resolve(import.meta.dir, "..");
const A = PAPERCUT_CHAT;
const B = "0190a000-0000-7000-8000-00000000fc02";
const FIRST_TEXT = `Answer ${TURNS}:`;
const SECOND_TEXT = `Reply ${TURNS}:`;

type Chat = { session: Record<string, unknown>; events: ReturnType<typeof papercutEvents>["events"] };
const first = papercutEvents({ turns: TURNS, running: false });
const chats = new Map<string, Chat>([
  [A, { session: first.session, events: first.events.map((event) => ({ ...event, sessionId: A })) }],
  [
    B,
    {
      session: { ...first.session, sessionId: B, title: "Second chat" },
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
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const chat = chats.get(String(params.sessionId)) ?? chats.get(A)!;
  const lastSeq = chat.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
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
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
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
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        calls.push({ method: message.method, at: Date.now(), sessionId: String(message.params?.sessionId ?? "") });
        if (message.id === undefined) return;
        const reply = JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: answer(message.method, message.params),
        });
        if (LATENCY > 0) setTimeout(() => ws.send(reply), LATENCY);
        else ws.send(reply);
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);

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
  const browser = await chromium.launch({ headless: true });
  releases.push(["browser", () => browser.close()]);

  type Round = { latest: number; settled: number; longTasks: number; longMs: number; shift: number; sent: string[] };
  const open = async (idle: number): Promise<Round> => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    calls = [];
    await page.goto(url);
    await page.waitForFunction((text) => document.body.textContent?.includes(text), FIRST_TEXT, {
      timeout: 120_000,
      polling: 100,
    });
    // A is painted: the unread arm switches before the read-ahead's delay, the other after it.
    await page.evaluate((idle) => new Promise<void>((resolve) => setTimeout(resolve, idle)), idle);
    calls = [];
    const got = await page.evaluate(
      ([id, text]) =>
        new Promise<{ latest: number; settled: number; longTasks: number; longMs: number; shift: number }>(
          (resolve, reject) => {
            const t0 = performance.now();
            const state = { latest: 0, activity: t0, longTasks: 0, longMs: 0, shift: 0, top: -1 };
            const afterPaint = (done: () => void) => requestAnimationFrame(() => setTimeout(done, 0));
            new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                if (entry.startTime < t0) continue;
                state.longTasks += 1;
                state.longMs += entry.duration;
                state.activity = Math.max(state.activity, entry.startTime + entry.duration);
              }
            }).observe({ type: "longtask" });
            new PerformanceObserver((list) => {
              for (const entry of list.getEntries() as unknown as {
                value: number;
                hadRecentInput: boolean;
                startTime: number;
              }[]) {
                if (entry.hadRecentInput || entry.startTime < t0) continue;
                state.shift += entry.value;
                state.activity = Math.max(state.activity, entry.startTime);
              }
            }).observe({ type: "layout-shift" });
            const tick = () => {
              const now = performance.now();
              if (!state.latest && document.body.textContent?.includes(text))
                afterPaint(() => (state.latest ||= performance.now()));
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              const top = scroller ? scroller.scrollTop + scroller.scrollHeight : -1;
              if (top !== state.top) {
                state.top = top;
                state.activity = Math.max(state.activity, now);
              }
              if (state.latest && now - Math.max(state.latest, state.activity) > 400) {
                resolve({
                  latest: state.latest - t0,
                  settled: Math.max(state.latest, state.activity) - t0,
                  longTasks: state.longTasks,
                  longMs: state.longMs,
                  shift: state.shift,
                });
                return;
              }
              if (now - t0 > 60_000) {
                reject(new Error(`${text} never painted`));
                return;
              }
              requestAnimationFrame(tick);
            };
            void (window as unknown as { cmuxAcpmuxActions: Record<string, (p: unknown) => Promise<unknown>> })
              .cmuxAcpmuxActions["chat.select"]!({ sessionId: id });
            requestAnimationFrame(tick);
          },
        ),
      [B, SECOND_TEXT] as const,
    );
    await page.close();
    return { ...got, sent: calls.map((call) => `${call.method}${call.sessionId === B ? " (B)" : ""}`) };
  };

  const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
  console.log(`chat-switch: ${TURNS} turns per chat, answers delayed ${LATENCY} ms, median of ${ROUNDS}`);
  console.log("arm | latest ms | settled ms | long tasks | long ms | layout shift");
  for (const [arm, idle] of [
    ["unread", 150],
    ["read ahead", 1200],
  ] as const) {
    await open(idle); // warm the server and the browser process
    const rounds: Round[] = [];
    for (let round = 0; round < ROUNDS; round++) rounds.push(await open(idle));
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
  }
} finally {
  await release();
}
