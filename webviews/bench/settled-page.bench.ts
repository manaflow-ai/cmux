// l10n-allow-file: bench fixture prompts and replies, and benchmark output, not shipped UI.
// Time to a settled page against a derived bound (goal settled-page-ceiling, cmuxterm-hq goals/settled-page-ceiling.md;
// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a settled page (zero
// layout shift after first paint, streaming included) within 2x of a derived bound").
//
// The production pane (a vite build of its dev entry, as chat-switch.bench.ts builds it) joins a stand-in acpmux that
// holds three TURNS-turn chats: A and B finished, S with a turn still running. No agent runs. Four transitions:
//   chat_switch       A shown and settled; the host selects the target chat (`cmuxAcpmuxActions["chat.select"]`, what
//                     the sidebar does). From the call.
//   workspace_switch  the target chat's page shown and settled, then hidden (its workspace left: visibilityState hidden,
//                     `visibilitychange`), a new turn arrives while hidden, then shown again. From the show.
//   open_recent       a second page for the target chat built in the warm renderer (another chat page open in the same
//                     context), as a released chat page opens again. From navigation.
//   restart           the target chat's page in a new (cold) context. From navigation.
// Each in two arms: `idle` (the target is B) and `stream` (the target is S, and the stand-in streams a reply chunk to S
// every STREAM_EVERY_MS from the transition on, for STREAM_MS).
//
// Per round, every painted frame from the transition's start is read (the transcript rows in view by id and top, the
// composer's box, the scroller's offset) and judged by the pane's own first-load judge (src/agent-session/acpmux/
// firstLoadFrames.ts `classifyFrames`, which firstLoadWatch.ts runs in the field):
//   settled_ms  when the final state first painted: from that frame on the rows in view and the composer stay put.
//   shifts      frames in which the composer or a row in view moved, or the bottom row was replaced.
// In the `stream` arm a growing reply is no shift: each frame's rows are placed in content coordinates (top plus the
// scroller's offset, so following the reply down is no move) and the bottom-most row (the one streaming) is left out.
//
// The derived bound: the same settled DOM (scripts removed), drawn with no app code at all, to its first paint, in the
// same state. For the in-page transitions (chat and workspace switch) the round's own page swaps its body for the
// settled copy and restores the scroller's offset; for the navigations (open recent, restart) a page in the same
// context state (warm renderer or cold context) loads the settled copy as a static document. It is what putting the
// final pixels up costs and nothing else, so `ratio = settled_ms / bound_ms` is how many bounds the app spends on data,
// React and scroll. The goal: ratio within 2 and no shift.
//
// Rows (PERF_ROW, bench/perfRow.ts; the perf cron stores each as webui.<name>):
//   settled_page.<scenario>.<arm>.{settled_ms,bound_ms,ratio,shifts}   medians, shifts the max over rounds
//   settled_page.score_max   the worst over every scenario and arm of median ratio + max shifts (NOW
//                            settled_page_score_max, cmuxterm-hq tools/fleet-reconcilers/now_benches.py)
//   SETTLED_PAGE_JSON {...}  every round's numbers, and each worst round's shift reasons.
//
//   bun bench/settled-page.bench.ts [rounds=3] [turns=120]
//   ONLY=chat_switch,restart  ARMS=idle  TRACE=1 (each scenario's worst round frame by frame)
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, BrowserContext, Page } from "playwright";
import { chromium } from "./browsers";
import { papercutEvents } from "../test/support/papercutChat";
import { classifyFrames, type FrameRecord } from "../src/agent-session/acpmux/firstLoadFrames";
import { perfRow } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 3);
const TURNS = Number(process.argv[3] ?? 120);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(TURNS) || TURNS < 2) {
  console.error("usage: bun bench/settled-page.bench.ts [rounds=3] [turns=120]");
  process.exit(2);
}
const SCENARIOS = ["chat_switch", "workspace_switch", "open_recent", "restart"] as const;
type Scenario = (typeof SCENARIOS)[number];
const ARMS = ["idle", "stream"] as const;
type Arm = (typeof ARMS)[number];
const only = process.env.ONLY?.split(",") as Scenario[] | undefined;
const arms = (process.env.ARMS?.split(",") as Arm[] | undefined) ?? [...ARMS];
const TRACE = process.env.TRACE === "1";
/// Frames are read for this long after the transition, then the read stops once nothing changed for QUIET_MS.
const MIN_WATCH_MS = 1_500;
const QUIET_MS = 800;
const MAX_WATCH_MS = 15_000;
const STREAM_EVERY_MS = 16;
const STREAM_MS = 2_500;
const VIEWPORT = { width: 1000, height: 800 };

const webviews = path.resolve(import.meta.dir, "..");
const A = "0190a000-0000-7000-8000-00000000fd01";
const B = "0190a000-0000-7000-8000-00000000fd02";
const S = "0190a000-0000-7000-8000-00000000fd03";
const MARK = `Answer ${TURNS}:`;

type Chat = { session: Record<string, unknown>; events: Record<string, unknown>[] };
const chatOf = (sessionId: string, title: string, running: boolean): Chat => {
  const { events, session } = papercutEvents({ turns: TURNS, running });
  return {
    session: { ...session, sessionId, title },
    events: events.map((event) => ({ ...event, sessionId })),
  };
};
const chats = new Map<string, Chat>([
  [A, chatOf(A, "First chat", false)],
  [B, chatOf(B, "Second chat", false)],
  [S, chatOf(S, "Streaming chat", true)],
]);

// ---------- the stand-in acpmux ----------
type Socket = { send(data: string): void };
const sockets = new Set<Socket>();
const lastSeq = (chat: Chat) => Number(chat.events.at(-1)?.seq ?? 0);
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const chat = chats.get(String(params.sessionId)) ?? chats.get(A)!;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [...chats.values()].map((one) => one.session) };
    case "_acpmux/attach": {
      const limit = Number(params.limit ?? 400);
      const events = chat.events.slice(-limit);
      return { session: chat.session, lastSeq: lastSeq(chat), events, hasMore: events.length < chat.events.length };
    }
    case "_acpmux/events": {
      if (params.beforeSeq !== undefined) {
        const before = Number(params.beforeSeq);
        const older = chat.events.filter((event) => Number(event.seq) < before);
        const page = older.slice(-Number(params.limit ?? 400));
        return { events: page, hasMore: page.length < older.length, lastSeq: lastSeq(chat) };
      }
      return { events: [], hasMore: false, lastSeq: lastSeq(chat) };
    }
    default:
      return null;
  }
};
/// Appends a record to `sessionId`'s log and sends it to every page, as acpmux's `_acpmux/event` does.
const append = (sessionId: string, dir: string, kind: string, msg: Record<string, unknown>) => {
  const chat = chats.get(sessionId)!;
  const event = { sessionId, seq: lastSeq(chat) + 1, at: Date.now(), dir, kind, msg };
  chat.events.push(event);
  chat.session = { ...chat.session, lastSeq: event.seq, updatedAt: event.at };
  const line = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
  for (const socket of sockets) socket.send(line);
};
const chunk = (sessionId: string, text: string) =>
  append(sessionId, "in", "agent_message_chunk", {
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
/// Streams reply chunks into S for STREAM_MS; resolves the stop.
let streamTimer: ReturnType<typeof setInterval> | undefined;
const startStream = () => {
  stopStream();
  const words = "The checks on the merged head are green and the retry loop now stops after three attempts. ".split(
    " ",
  );
  let at = 0;
  const started = Date.now();
  streamTimer = setInterval(() => {
    if (Date.now() - started > STREAM_MS) return stopStream();
    chunk(S, `${words[at % words.length]} `);
    at += 1;
  }, STREAM_EVERY_MS);
};
function stopStream() {
  if (streamTimer) clearInterval(streamTimer);
  streamTimer = undefined;
}
/// A finished turn arriving in `sessionId` (the workspace-switch arm: what changed while the page was hidden).
let extraTurns = 0;
const newTurn = (sessionId: string) => {
  extraTurns += 1;
  append(sessionId, "mux", "user_message", { text: `Follow-up ${extraTurns}` });
  append(sessionId, "mux", "turn_started", {});
  chunk(sessionId, `Follow-up answer ${extraTurns}: done, the branch is pushed and the checks are queued.`);
  append(sessionId, "mux", "turn_result", { status: "completed" });
};

const releases: (() => unknown)[] = [];
const release = async () => {
  stopStream();
  for (const stop of releases.reverse())
    try {
      await stop();
    } catch {}
};

// ---------- the page side ----------
/** Init script: the frame reader. Self-contained (Playwright serializes it). Reads once per frame after paint. */
function installFrameReader() {
  type Rec = {
    t: number;
    copyShown: boolean;
    rows: { id: string; top: number }[];
    composer: { top: number; height: number } | null;
    scrollTop: number | null;
  };
  const w = window as unknown as {
    __settle?: { start(t0: number): void; stop(): { t0: number; frames: Rec[]; lastChange: number } };
    __hidden?: boolean;
  };
  if (w.__settle) return;
  // The workspace-switch arm's visibility: the page reads hidden while its workspace is not shown.
  w.__hidden = false;
  Object.defineProperty(Document.prototype, "visibilityState", {
    configurable: true,
    get: () => (w.__hidden ? "hidden" : "visible"),
  });
  Object.defineProperty(Document.prototype, "hidden", { configurable: true, get: () => !!w.__hidden });
  const raf = window.requestAnimationFrame.bind(window);
  let frames: Rec[] = [];
  let t0 = 0;
  let running = false;
  let lastKey = "";
  let lastChange = 0;
  const read = (): Rec => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    const rows: Rec["rows"] = [];
    if (scroller) {
      const view = scroller.getBoundingClientRect();
      for (const row of scroller.querySelectorAll<HTMLElement>("[data-row-id]")) {
        const box = row.getBoundingClientRect();
        if (box.height > 0 && box.bottom > view.top && box.top < view.bottom)
          rows.push({ id: row.dataset.rowId ?? "", top: box.top });
      }
    }
    const composerBox = document.querySelector<HTMLElement>(".acpmux-composer-box")?.getBoundingClientRect();
    return {
      t: performance.now(),
      copyShown: !!document.querySelector("cmux-chat-snapshot"),
      rows,
      composer: composerBox ? { top: composerBox.top, height: composerBox.height } : null,
      scrollTop: scroller ? scroller.scrollTop : null,
    };
  };
  const tick = () => {
    if (!running) return;
    // After this frame painted: a task queued from the frame callback runs once the frame is drawn.
    setTimeout(() => {
      if (!running) return;
      const rec = read();
      const key = JSON.stringify([rec.rows, rec.composer, rec.scrollTop]);
      if (key !== lastKey) {
        lastKey = key;
        lastChange = rec.t;
      }
      frames.push(rec);
    }, 0);
    raf(tick);
  };
  w.__settle = {
    start(at: number) {
      frames = [];
      t0 = at;
      lastKey = "";
      lastChange = at;
      running = true;
      raf(tick);
    },
    stop() {
      running = false;
      return { t0, frames, lastChange };
    },
  };
  // A navigation arm starts at once, from navigation (t0 = 0).
  if ((window as unknown as { __settleAtLoad?: boolean }).__settleAtLoad) w.__settle.start(0);
}

type Read = { t0: number; frames: FrameRecord[]; lastChange: number };
/** Waits until the page painted MARK, MIN_WATCH_MS passed and nothing changed for QUIET_MS; returns the frames. */
async function watch(page: Page, mark: string): Promise<Read> {
  const started = Date.now();
  for (;;) {
    // fixed-wait: the frame reader runs in the page; this only decides when to stop reading.
    await page.waitForTimeout(100);
    const state = await page.evaluate(
      (mark) => ({
        now: performance.now(),
        painted: !!document.querySelector(".acpmux-scroll")?.textContent?.includes(mark),
        last: (window as unknown as { __settleLast?: number }).__settleLast,
      }),
      mark,
    );
    const elapsed = Date.now() - started;
    if (elapsed > MAX_WATCH_MS) break;
    if (!state.painted || elapsed < MIN_WATCH_MS) continue;
    const quiet = await page.evaluate(() => {
      const w = window as unknown as { __settle: { stop(): Read } & Record<string, unknown> };
      // Peek without stopping: the reader's lastChange is on its closure; stop and restart is not needed, so read
      // the newest frame's time against the last change through a stop only when quiet.
      return w.__settle;
    });
    void quiet;
    const last = await page.evaluate(() => {
      const w = window as unknown as { __settle: { stop(): Read; start(t0: number): void } };
      const read = w.__settle.stop();
      // Keep reading: put the frames back by restarting with the same t0 and the frames kept.
      (window as unknown as { __settleKept?: Read }).__settleKept = read;
      return { lastChange: read.lastChange, now: performance.now() };
    });
    const kept = await page.evaluate(() => (window as unknown as { __settleKept: Read }).__settleKept);
    if (last.now - last.lastChange >= QUIET_MS) return kept;
    // Not quiet yet: resume, carrying the frames read so far.
    await page.evaluate(() => {
      const w = window as unknown as { __settle: { start(t0: number): void; stop(): Read } };
      const kept = (window as unknown as { __settleKept: Read }).__settleKept;
      w.__settle.start(kept.t0);
      (window as unknown as { __settleCarry?: Read }).__settleCarry = kept;
    });
    const carry = await page.evaluate(() => (window as unknown as { __settleCarry?: Read }).__settleCarry);
    if (carry) carried.set(page, [...(carried.get(page) ?? []), ...carry.frames]);
  }
  const read = await page.evaluate(() => (window as unknown as { __settle: { stop(): Read } }).__settle.stop());
  return read;
}
const carried = new WeakMap<Page, FrameRecord[]>();
/** Stops the reader and returns every frame read since the transition, carried pieces included. */
async function framesOf(page: Page, mark: string): Promise<Read> {
  carried.delete(page);
  const read = await watch(page, mark);
  const before = carried.get(page) ?? [];
  carried.delete(page);
  return { ...read, frames: [...before, ...read.frames] };
}

/** The stream arm's view of a frame: rows in content coordinates, the streaming (bottom-most) row left out. */
function streamView(frame: FrameRecord): FrameRecord {
  const offset = frame.scrollTop ?? 0;
  const rows = frame.rows.map((row) => ({ id: row.id, top: row.top + offset }));
  let bottom = -1;
  rows.forEach((row, at) => {
    if (bottom < 0 || row.top >= rows[bottom]!.top) bottom = at;
  });
  return { ...frame, rows: rows.filter((_, at) => at !== bottom) };
}

type Judged = { settledMs: number; shifts: number; why: string[]; frames: number };
function judge(read: Read, arm: Arm): Judged {
  const frames = read.frames.filter((frame) => frame.t >= read.t0);
  const view = arm === "stream" ? frames.map(streamView) : frames;
  const metrics = classifyFrames(view);
  const settledAt = metrics.finalFirstPaintMs ?? frames.at(-1)?.t ?? read.t0;
  return {
    settledMs: Math.max(0, settledAt - read.t0),
    shifts: metrics.shiftFrames,
    why: metrics.shiftAt.slice(0, 5).map((one) => `@${(frames[one.index]!.t - read.t0).toFixed(0)}ms ${one.why}`),
    frames: frames.length,
  };
}

/** The settled DOM, scripts removed, and the scroller's offset. */
async function settledCopy(page: Page): Promise<{ html: string; body: string; scrollTop: number }> {
  return page.evaluate(() => {
    const clone = document.documentElement.cloneNode(true) as HTMLElement;
    for (const node of clone.querySelectorAll("script")) node.remove();
    return {
      html: `<!doctype html>${clone.outerHTML}`,
      body: clone.querySelector("body")?.innerHTML ?? "",
      scrollTop: document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0,
    };
  });
}

/** In-page bound: swap the body for the settled copy, restore the offset, time to the next painted frame. */
async function boundInPage(page: Page, copy: { body: string; scrollTop: number }): Promise<number> {
  return page.evaluate(
    ({ body, scrollTop }) =>
      new Promise<number>((resolve) => {
        const t0 = performance.now();
        document.body.innerHTML = body;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (scroller) scroller.scrollTop = scrollTop;
        requestAnimationFrame(() => setTimeout(() => resolve(performance.now() - t0), 0));
      }),
    copy,
  );
}

/** Navigation bound: a page in `context` loads the settled copy as a static document; navigation to its first paint. */
let boundHtml = "";
async function boundNavigation(context: BrowserContext, base: string, copy: { html: string; scrollTop: number }) {
  boundHtml = copy.html.replace(
    "</body>",
    `<script>{const s=document.querySelector(".acpmux-scroll");if(s)s.scrollTop=${copy.scrollTop};` +
      `requestAnimationFrame(()=>setTimeout(()=>{window.__boundPaint=performance.now()},0))}</script></body>`,
  );
  const page = await context.newPage();
  await page.goto(`${base}/__bound.html`);
  await page.waitForFunction(() => (window as unknown as { __boundPaint?: number }).__boundPaint, null, {
    timeout: 30_000,
  });
  const ms = await page.evaluate(() => (window as unknown as { __boundPaint: number }).__boundPaint);
  await page.close();
  return ms;
}

type Round = Judged & { boundMs: number; ratio: number };
const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};

try {
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
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  releases.push(() => daemon.stop(true));

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "settled-page-bench-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
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
      if (pathname === "/__bound.html") return new Response(boundHtml, { headers: { "content-type": "text/html" } });
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const base = `http://127.0.0.1:${statics.port}`;
  const urlFor = (session: string) =>
    `${base}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${session}`;

  const browser: Browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  const newContext = async (atLoad: boolean) => {
    const context = await browser.newContext({ viewport: VIEWPORT });
    if (atLoad)
      await context.addInitScript(() => ((window as unknown as { __settleAtLoad: boolean }).__settleAtLoad = true));
    await context.addInitScript(installFrameReader);
    return context;
  };
  const waitPainted = (page: Page, mark: string) =>
    page.waitForFunction((mark) => document.querySelector(".acpmux-scroll")?.textContent?.includes(mark), mark, {
      timeout: 60_000,
      polling: 100,
    });
  const settleIdle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => setTimeout(resolve, 1_200)), // fixed-wait: let the shown page come to rest
    );
  const start = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __settle: { start(t0: number): void } };
      const t0 = performance.now();
      w.__settle.start(t0);
      return t0;
    });

  const one = async (scenario: Scenario, arm: Arm): Promise<Round> => {
    const target = arm === "stream" ? S : B;
    let context: BrowserContext | undefined;
    let warm: BrowserContext | undefined;
    try {
      let page: Page;
      if (scenario === "chat_switch") {
        context = await newContext(false);
        page = await context.newPage();
        await page.goto(urlFor(A));
        await waitPainted(page, MARK);
        await settleIdle(page);
        await start(page);
        if (arm === "stream") startStream();
        await page.evaluate(
          (id) =>
            void (
              window as unknown as {
                cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
              }
            ).cmuxAcpmuxActions["chat.select"]!({ sessionId: id }),
          target,
        );
      } else if (scenario === "workspace_switch") {
        context = await newContext(false);
        page = await context.newPage();
        await page.goto(urlFor(target));
        await waitPainted(page, MARK);
        await settleIdle(page);
        await page.evaluate(() => {
          (window as unknown as { __hidden: boolean }).__hidden = true;
          document.dispatchEvent(new Event("visibilitychange"));
        });
        newTurn(target);
        await settleIdle(page);
        if (arm === "stream") startStream();
        await page.evaluate(() => {
          (window as unknown as { __hidden: boolean }).__hidden = false;
          const w = window as unknown as { __settle: { start(t0: number): void } };
          w.__settle.start(performance.now());
          document.dispatchEvent(new Event("visibilitychange"));
        });
      } else if (scenario === "open_recent") {
        context = await newContext(true);
        const other = await context.newPage();
        await other.goto(urlFor(A));
        await waitPainted(other, MARK);
        if (arm === "stream") startStream();
        page = await context.newPage();
        await page.goto(urlFor(target));
      } else {
        // restart: warm the build's cache in one context, then the measured page in a cold one.
        context = await newContext(true);
        if (arm === "stream") startStream();
        page = await context.newPage();
        await page.goto(urlFor(target));
      }
      const read = await framesOf(page, MARK);
      stopStream();
      const judged = judge(read, arm);
      const copy = await settledCopy(page);
      let boundMs: number;
      if (scenario === "chat_switch" || scenario === "workspace_switch") boundMs = await boundInPage(page, copy);
      else if (scenario === "open_recent") boundMs = await boundNavigation(context, base, copy);
      else {
        warm = await browser.newContext({ viewport: VIEWPORT });
        boundMs = await boundNavigation(warm, base, copy);
      }
      return { ...judged, boundMs, ratio: judged.settledMs / Math.max(boundMs, 1) };
    } finally {
      stopStream();
      await context?.close();
      await warm?.close();
    }
  };

  const report: Record<string, { rounds: Round[] }> = {};
  let score = 0;
  let worst = "";
  for (const scenario of SCENARIOS.filter((name) => !only || only.includes(name)))
    for (const arm of arms) {
      const rounds: Round[] = [];
      for (let round = 0; round < ROUNDS; round += 1) rounds.push(await one(scenario, arm));
      const name = `settled_page.${scenario}.${arm}`;
      const settled = median(rounds.map((r) => r.settledMs));
      const bound = median(rounds.map((r) => r.boundMs));
      const ratio = median(rounds.map((r) => r.ratio));
      const shifts = Math.max(...rounds.map((r) => r.shifts));
      perfRow({ name: `${name}.settled_ms`, p50: settled, p95: Math.max(...rounds.map((r) => r.settledMs)) });
      perfRow({ name: `${name}.bound_ms`, p50: bound, p95: Math.max(...rounds.map((r) => r.boundMs)) });
      perfRow({ name: `${name}.ratio`, p50: ratio, p95: ratio, unit: "x", target: 2, floor: 0.3 });
      perfRow({ name: `${name}.shifts`, p50: shifts, p95: shifts, unit: "count", target: 0, floor: 0.5 });
      const value = ratio + shifts;
      if (value > score) {
        score = value;
        worst = name;
      }
      report[name] = { rounds };
      console.log(
        `${name}: settled ${settled.toFixed(0)} ms, bound ${bound.toFixed(1)} ms, ratio ${ratio.toFixed(2)}, shifts ${shifts}` +
          (shifts ? ` (${rounds.find((r) => r.shifts === shifts)!.why.join("; ")})` : ""),
      );
      if (TRACE) for (const r of rounds) console.log(`  round: ${JSON.stringify(r)}`);
    }
  perfRow({ name: "settled_page.score_max", p50: score, p95: score, unit: "x", target: 2, floor: 0.3 });
  console.log(`settled_page.score_max ${score.toFixed(2)} (worst ${worst}; target <= 2)`);
  console.log(`SETTLED_PAGE_JSON ${JSON.stringify({ score, worst, turns: TURNS, rounds: ROUNDS, report })}`);
} finally {
  await release();
}
