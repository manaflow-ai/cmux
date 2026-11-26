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
//   open_recent       a released chat page opens again in the warm renderer: first-load-after-restart.bench.ts MODE=reopen
//                     (the app's serving path: the saved copy, the kept tail, acpmux up). From navigation.
//   restart           the app relaunches: first-load-after-restart.bench.ts MODE=native-ready (a cold context, PAGES
//                     restored pages, the saved copy while acpmux comes back). From navigation.
// The two navigations run that bench (BOUND=1, RUNNING=1 for the stream arm) and take its rounds: settled_ms is its
// final first paint, shifts its shift frames, bound_ms its derived bound.
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
// settled copy and restores the scroller's offset; for the navigations (open recent, restart) the restart bench loads
// the settled copy as a static document in the same context state (warm renderer or cold context). It is what putting the
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
//   PROFILE=1 (an unminified build and a CPU profile of each chat switch: its top functions)
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, BrowserContext, CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { papercutEvents } from "../test/support/papercutChat";
import { classifyFrames, MOVE_TOLERANCE_PX, type FrameRecord } from "../src/agent-session/acpmux/firstLoadFrames";
import { perfRow } from "./perfRow";
import { segmenter } from "./replySegments";

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
// PROFILE=1: an unminified build and a CPU profile of each chat switch, its top functions by self and total time.
const PROFILE = process.env.PROFILE === "1";

type CpuProfile = {
  nodes: {
    id: number;
    parent?: number;
    children?: number[];
    callFrame: { functionName: string; url: string; lineNumber: number };
  }[];
  samples: number[];
  timeDeltas: number[];
};
/// PROFILE's report: the switch's first 150 ms of samples, the top functions by self time and by total time.
function printProfile(label: string, profile: CpuProfile) {
  const keep = process.env.FAST_CHECKS_OUT ?? process.env.PROFILE_OUT;
  if (keep) fs.writeFileSync(path.join(keep, `${label}-${Date.now()}.cpuprofile`), JSON.stringify(profile));
  console.log(
    `  ${label} profile: ${profile.samples.length} samples over ${(profile.timeDeltas.reduce((x, y) => x + y, 0) / 1000).toFixed(0)} ms`,
  );
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const name = (id: number) => {
    const frame = byId.get(id)!.callFrame;
    return `${frame.functionName || "(anon)"} ${frame.url.split("/").pop()}:${frame.lineNumber + 1}`;
  };
  const self = new Map<string, number>();
  const total = new Map<string, number>();
  // The window starts at the switch's first busy sample, not the profile's start: the first time delta carries the
  // profiler's own start offset, which alone ran past the window and left the report empty.
  const idle = (id: number) => ["(idle)", "(program)"].includes(byId.get(id)!.callFrame.functionName);
  let t = 0;
  let from: number | undefined;
  for (let i = 0; i < profile.samples.length; i += 1) {
    t += profile.timeDeltas[i]! / 1000;
    if (from === undefined && !idle(profile.samples[i]!)) from = t;
    if (from === undefined) continue;
    if (t - from > 150) break;
    const dt = (profile.timeDeltas[i + 1] ?? 100) / 1000;
    const leaf = profile.samples[i]!;
    self.set(name(leaf), (self.get(name(leaf)) ?? 0) + dt);
    const seen = new Set<string>();
    for (let id: number | undefined = leaf; id !== undefined; id = parent.get(id)) {
      const key = name(id);
      if (seen.has(key)) continue;
      seen.add(key);
      total.set(key, (total.get(key) ?? 0) + dt);
    }
  }
  const top = (map: Map<string, number>, count: number) =>
    [...map]
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key, ms]) => `      ${ms.toFixed(1)}ms ${key}`);
  console.log(`  ${label} profile, self:`);
  for (const line of top(self, 20)) console.log(line);
  console.log(`  ${label} profile, total:`);
  for (const line of top(total, 45)) console.log(line);
}
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
/// Each chat's own words and row ids: B's answers read differently, and each chat's records number from its own base,
/// so no row id is shared between chats (a shared id would read as one row moving across a switch, identical chats as
/// no change at all) and a row id names its chat.
const WORD = new Map([
  [A, "Answer"],
  [B, "Reply"],
  [S, "Answer"],
]);
/// The text a painted page of `chat` shows at its end: its newest prompt. Each workspace_switch round adds a turn to its
/// target (`newTurn`), so after a dozen rounds the seed's last turn ("Answer 120:") is above the rows a page mounts at
/// the latest row, and a wait for it never ended (the 60 s first-paint timeout in round 13 of workspace_switch.stream).
const newestMark = new Map<string, string>();
const markOf = (chat: string) => newestMark.get(chat) ?? `${WORD.get(chat)} ${TURNS}:`;
const SEQ_SPAN = 100_000;
const SEQ_BASE = new Map([
  [A, 0],
  [B, SEQ_SPAN],
  [S, 2 * SEQ_SPAN],
]);
/** Whether a row id (`assistant-100479`, `working-user-481`) is one of `chat`'s rows. */
const rowOf = (rowId: string, chat: string) => {
  const seq = Number(/(\d+)$/.exec(rowId)?.[1] ?? NaN);
  const base = SEQ_BASE.get(chat)!;
  return seq > base && seq <= base + SEQ_SPAN;
};

const segmenters = new Map<string, ReturnType<typeof segmenter>>();

type Chat = { session: Record<string, unknown>; events: Record<string, unknown>[] };
const chatOf = (sessionId: string, title: string, running: boolean): Chat => {
  const word = WORD.get(sessionId)!;
  const { events, session } = papercutEvents({
    turns: TURNS,
    running,
    answer: (n) => `${word} ${n}: the checks on the merged head are green.`,
  });
  const base = SEQ_BASE.get(sessionId)!;
  const stamp = segmenter();
  segmenters.set(sessionId, stamp);
  for (const event of events) stamp(event as Parameters<typeof stamp>[0]);
  return {
    session: { ...session, sessionId, title, lastSeq: Number(session.lastSeq) + base },
    events: events.map((event) => ({ ...event, sessionId, seq: Number(event.seq) + base })),
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
      // As acpmux's attach (server/requests/turn_opener.rs): a page that starts inside a turn carries that turn's prompt.
      const first = events[0];
      const turnOpener =
        first && first.kind !== "user_message" && events.length < chat.events.length
          ? ([...chat.events]
              .reverse()
              .find((event) => event.kind === "user_message" && Number(event.seq) < Number(first.seq)) ?? null)
          : null;
      return {
        session: chat.session,
        lastSeq: lastSeq(chat),
        events,
        hasMore: events.length < chat.events.length,
        turnOpener,
      };
    }
    case "_acpmux/events": {
      if (params.beforeSeq !== undefined) {
        const before = Number(params.beforeSeq);
        // acpmux reads only the kinds asked: a read without "transcript" (the turn opener's, the prompt index's) is
        // those records alone. With it, every record here is a transcript one.
        const kinds = Array.isArray(params.kinds) ? (params.kinds as string[]) : undefined;
        const asked = (event: { kind?: unknown }) =>
          !kinds || kinds.includes("transcript") || kinds.includes(String(event.kind));
        const older = chat.events.filter((event) => Number(event.seq) < before && asked(event));
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
  segmenters.get(sessionId)?.(event);
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
/// A turn arriving in `sessionId` while the page is hidden (the workspace-switch arm). Idle: a finished turn. Running
/// (the stream arm): the running turn ends and a new one starts and stays open, so the stream that follows is that
/// turn's reply, as acpmux sends it; a chunk after a turn's result opens no turn there.
let extraTurns = 0;
const newTurn = (sessionId: string, running = false) => {
  extraTurns += 1;
  if (running) append(sessionId, "mux", "turn_result", { status: "completed" });
  append(sessionId, "mux", "user_message", { text: `Follow-up ${extraTurns}: what is left?` });
  newestMark.set(sessionId, `Follow-up ${extraTurns}:`);
  append(sessionId, "mux", "turn_started", {});
  chunk(sessionId, `Follow-up answer ${extraTurns}: done, the branch is pushed and the checks are queued.`);
  if (!running) append(sessionId, "mux", "turn_result", { status: "completed" });
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
    rows: { id: string; top: number; bottom: number }[];
    composer: { top: number; height: number } | null;
    scrollTop: number | null;
    drawnBy?: number;
  };
  const w = window as unknown as {
    __settle?: {
      start(t0: number): void;
      peek(): { lastChange: number; now: number };
      stop(): { t0: number; frames: Rec[]; lastChange: number; marks: { t: number; what: string }[] };
    };
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
  // TRACE's timeline: each socket message out and in (its method, or the id it answers) and each long task.
  const marks: { t: number; what: string }[] = [];
  const mark = (what: string) => marks.push({ t: performance.now(), what });
  const Native = window.WebSocket;
  const asked = new Map<unknown, string>();
  window.WebSocket = class extends Native {
    constructor(url: string | URL, protocols?: string | string[]) {
      super(url, protocols);
      this.addEventListener("message", (event) => {
        try {
          const msg = JSON.parse(String(event.data)) as { id?: unknown; method?: string; params?: { kind?: string } };
          const what = msg.method ?? `answer ${String(asked.get(msg.id) ?? msg.id)}`;
          mark(`in ${what}${msg.params?.kind ? ` ${msg.params.kind}` : ""} ${String(event.data).length}B`);
        } catch {
          mark("in ?");
        }
      });
    }
    send(data: string | ArrayBufferLike | Blob | ArrayBufferView) {
      try {
        const msg = JSON.parse(String(data)) as { id?: unknown; method?: string; params?: Record<string, unknown> };
        if (msg.method) asked.set(msg.id, msg.method);
        // A read of records names its cursor, so a large catch-up says which read asked for it.
        const cursor = ["afterSeq", "beforeSeq", "limit", "kinds"]
          .filter((key) => msg.params?.[key] !== undefined)
          .map((key) => `${key}=${JSON.stringify(msg.params![key])}`)
          .join(" ");
        mark(`out ${msg.method ?? "answer"}${cursor ? ` ${cursor}` : ""}`);
      } catch {
        mark("out ?");
      }
      super.send(data as Parameters<WebSocket["send"]>[0]);
    }
  } as typeof WebSocket;
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries())
        marks.push({ t: entry.startTime, what: `longtask ${entry.duration.toFixed(0)}ms` });
    }).observe({ type: "longtask", buffered: false });
  } catch {
    // no long task timing in this engine
  }
  const raf = window.requestAnimationFrame.bind(window);
  let frames: Rec[] = [];
  let t0 = 0;
  let running = false;
  let lastKey = "";
  let lastChange = 0;
  // As firstLoadWatch.ts `readFrame` reads a frame: the drawn copy's layer when it shows, else the live page.
  const read = (): Rec => {
    const drawn = document.querySelector<HTMLElement>("cmux-chat-snapshot");
    const host = drawn && drawn.style.visibility !== "hidden" && drawn.style.opacity !== "0" ? drawn : null;
    const scope: ParentNode = host?.shadowRoot ?? document;
    const rootHidden = !host && document.getElementById("root")?.style.opacity === "0";
    const scroller = scope.querySelector<HTMLElement>(".acpmux-scroll");
    const view = rootHidden ? undefined : scroller?.getBoundingClientRect();
    const rows: Rec["rows"] = [];
    if (view)
      for (const row of Array.from(scope.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))) {
        const box = row.getBoundingClientRect();
        if (box.height > 0 && box.bottom > view.top && box.top < view.bottom)
          rows.push({ id: row.dataset.rowId ?? "", top: box.top, bottom: box.bottom });
      }
    rows.sort((x, y) => x.top - y.top);
    const composer = rootHidden
      ? undefined
      : Array.from(scope.querySelectorAll(".acpmux-composer-box"))
          .map((element) => element.getBoundingClientRect())
          .find((box) => box.height > 0);
    return {
      t: performance.now(),
      copyShown: !!host,
      rows,
      composer: composer ? { top: composer.top, height: composer.height } : null,
      scrollTop: scroller && !rootHidden ? scroller.scrollTop : null,
      // How far the thread is drawn from its place (the follow glide's translate): a row's place in the content is
      // its box less this, as VirtualTranscript's own `drawnBy` reads it.
      drawnBy: (() => {
        const thread = scroller?.querySelector<HTMLElement>(".acpmux-thread");
        const translate = thread ? getComputedStyle(thread).translate : "none";
        return translate && translate !== "none" ? Number.parseFloat(translate.split(" ")[1] ?? "") || 0 : 0;
      })(),
      ...(scroller
        ? {
            geo: `sh=${scroller.scrollHeight} ch=${scroller.clientHeight} thread=${(() => {
              const thread = scroller.querySelector<HTMLElement>(".acpmux-thread");
              return thread
                ? `${thread.style.cssText.replace(/\s+/g, "")}|h=${thread.getBoundingClientRect().height.toFixed(1)}`
                : "-";
            })()}`,
          }
        : {}),
    };
  };
  const tick = () => {
    if (!running) return;
    // As this frame paints: a ResizeObserver made in the frame callback is the last one the frame delivers to (its
    // first delivery comes in this frame's rendering steps, after layout), so it reads the rows after the app's own
    // observers placed them, as the frame then paints them. A task queued from the frame callback ran after a commit
    // that a task before it made: it read that commit's rows before the frame that placed them (a reply's measured
    // growth read at its old place, 432 px off, in chat_switch stream's later rounds).
    const reader = new ResizeObserver(() => {
      reader.disconnect();
      if (!running) return;
      const rec = read();
      const key = JSON.stringify([rec.rows, rec.composer, rec.scrollTop]);
      if (key !== lastKey) {
        lastKey = key;
        lastChange = rec.t;
      }
      frames.push(rec);
    });
    reader.observe(document.documentElement);
    raf(tick);
  };
  w.__settle = {
    start(at: number) {
      frames = [];
      marks.length = 0;
      t0 = at;
      lastKey = "";
      lastChange = at;
      running = true;
      raf(tick);
    },
    peek() {
      return { lastChange, now: performance.now() };
    },
    stop() {
      running = false;
      return { t0, frames, lastChange, marks: marks.slice() };
    },
  };
}

type Read = {
  t0: number;
  frames: FrameRecord[];
  lastChange: number;
  marks: { t: number; what: string }[];
  vt?: string[];
};
type Reader = { start(t0: number): void; peek(): { lastChange: number; now: number }; stop(): Read };
/** Reads until the page painted `mark`, MIN_WATCH_MS passed and nothing changed for QUIET_MS (or MAX_WATCH_MS); returns
 * every frame read since the transition. */
async function framesOf(page: Page, mark: string): Promise<Read> {
  const started = Date.now();
  while (Date.now() - started < MAX_WATCH_MS) {
    // fixed-wait: the frame reader runs in the page; this only decides when to stop reading.
    await page.waitForTimeout(100);
    const state = await page.evaluate(
      (mark) => ({
        painted: !!document.querySelector(".acpmux-scroll")?.textContent?.includes(mark),
        ...(window as unknown as { __settle: Reader }).__settle.peek(),
      }),
      mark,
    );
    if (state.painted && Date.now() - started >= MIN_WATCH_MS && state.now - state.lastChange >= QUIET_MS) break;
  }
  return page.evaluate(() => (window as unknown as { __settle: Reader }).__settle.stop());
}

/** A row's bottom edge in the frame, its top when the frame did not read one. */
const bottomOfRow = (row: FrameRecord["rows"][number]) => (row as { bottom?: number }).bottom ?? row.top;

/** How far a frame's thread was drawn from its place (the follow glide), 0 when not read. */
const drawnBy = (frame: FrameRecord) => (frame as { drawnBy?: number }).drawnBy ?? 0;

/**
 * The stream arm's view of a frame: rows in content coordinates, the streaming (bottom-most) row left out. A row's
 * place in the content leaves out the follow glide's translate: the glide eases the view after the reply, so with it
 * counted every row above crept ~1.6 px a frame in the content for 2.5 s (109 "shifts" in workspace_switch stream).
 */
function streamView(frame: FrameRecord): FrameRecord {
  const offset = (frame.scrollTop ?? 0) - drawnBy(frame);
  const rows = frame.rows.map((row) => ({ id: row.id, top: row.top + offset, bottom: bottomOfRow(row) + offset }));
  let bottom = -1;
  rows.forEach((row, at) => {
    if (bottom < 0 || row.top >= rows[bottom]!.top) bottom = at;
  });
  return { ...frame, rows: rows.filter((_, at) => at !== bottom) };
}

/**
 * The stream arm's judge. The view follows the growing reply, so rows leave the top of the view and the reply's own
 * row grows and may change identity (the working row becomes the answer): none of that is a shift. A shift is a row
 * seen in two frames in a row (the bottom-most left out) that moved both in the view and in the content: following
 * the reply moves rows in the view only, and a height read above that the scroll offset absorbs (the view held still)
 * moves them in the content only, and neither is seen. A composer that moved is a shift too.
 * Settled: the first frame from which no such move happens again and the final bottom row is already shown.
 */
function judgeStream(frames: FrameRecord[], t0: number): Judged {
  const views = frames.map(streamView);
  const moved = (a: FrameRecord, b: FrameRecord): string | null => {
    const before = new Map(a.rows.map((row) => [row.id, row]));
    const offset = (frame: FrameRecord) => (frame.scrollTop ?? 0) - drawnBy(frame);
    // The reply streaming above the live row: the bottom-most row left after `streamView` took the live row out. When
    // it grew with its foot held in the view, the view followed it: its top and every row above it rose by its growth
    // in the view. In a frame where nothing above changed that is a view move only, which the content check below
    // already passes; in the frame where the history mounts above (every row's content top moves, the offset absorbs
    // it), the same follow read as a shift of the reply and each row above it.
    const reply = b.rows.reduce<FrameRecord["rows"][number] | undefined>(
      (best, row) => (!best || row.top >= best.top ? row : best),
      undefined,
    );
    const replyBefore = reply && before.get(reply.id);
    let follow: number | undefined;
    if (reply && replyBefore) {
      const rise = reply.top - offset(b) - (replyBefore.top - offset(a));
      const footMoved = bottomOfRow(reply) - offset(b) - (bottomOfRow(replyBefore) - offset(a));
      const grew = bottomOfRow(reply) - reply.top - (bottomOfRow(replyBefore) - replyBefore.top);
      if (
        grew > MOVE_TOLERANCE_PX &&
        Math.abs(footMoved) <= 2 * MOVE_TOLERANCE_PX &&
        Math.abs(rise + grew) <= 2 * MOVE_TOLERANCE_PX
      )
        follow = rise;
    }
    for (const row of b.rows) {
      const top = before.get(row.id)?.top;
      if (top === undefined || Math.abs(top - row.top) <= MOVE_TOLERANCE_PX) continue;
      const [viewA, viewB] = [top - offset(a), row.top - offset(b)];
      if (follow !== undefined && Math.abs(viewB - viewA - follow) <= 2 * MOVE_TOLERANCE_PX) continue;
      if (Math.abs(viewA - viewB) > MOVE_TOLERANCE_PX)
        return `row ${row.id} view ${viewA.toFixed(1)} -> ${viewB.toFixed(1)}, content ${top.toFixed(1)} -> ${row.top.toFixed(1)}`;
    }
    const [ca, cb] = [a.composer, b.composer];
    if (
      ca &&
      cb &&
      (Math.abs(ca.top - cb.top) > MOVE_TOLERANCE_PX || Math.abs(ca.height - cb.height) > MOVE_TOLERANCE_PX)
    )
      return `composer ${ca.top.toFixed(1)}+${ca.height.toFixed(1)} -> ${cb.top.toFixed(1)}+${cb.height.toFixed(1)}`;
    return null;
  };
  const bottomOf = (frame: FrameRecord) =>
    frame.rows.reduce<{ id: string; top: number } | null>(
      (best, row) => (!best || row.top >= best.top ? row : best),
      null,
    )?.id ?? null;
  const finalBottom = frames.length ? bottomOf(frames.at(-1)!) : null;
  const why: string[] = [];
  let lastMove = -1;
  for (let at = 1; at < views.length; at += 1) {
    const reason = moved(views[at - 1]!, views[at]!);
    if (!reason) continue;
    lastMove = at;
    if (why.length < 5) why.push(`@${(frames[at]!.t - t0).toFixed(0)}ms ${reason}`);
  }
  let settled = Math.max(0, lastMove);
  while (settled < frames.length - 1 && bottomOf(frames[settled]!) !== finalBottom) settled += 1;
  const shifts = views.slice(1).filter((view, at) => moved(views[at]!, view)).length;
  return { settledMs: frames.length ? Math.max(0, frames[settled]!.t - t0) : 0, shifts, why, frames: frames.length };
}

type Judged = { settledMs: number; shifts: number; why: string[]; frames: number };
function judge(read: Read, arm: Arm, target: string): Judged {
  // The chat on screen before the switch stays until the target draws (no blank between): judged from the first frame
  // showing any of the target's rows. A frame mixing both chats is still judged (an oddity).
  const after = read.frames.filter((frame) => frame.t >= read.t0);
  const first = after.findIndex((frame) => frame.rows.some((row) => rowOf(row.id, target)));
  const frames = first < 0 ? after : after.slice(first);
  if (arm === "stream") return judgeStream(frames, read.t0);
  const view = frames;
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
async function settledCopy(page: Page): Promise<{ body: string; scrollTop: number }> {
  return page.evaluate(() => {
    const clone = document.documentElement.cloneNode(true) as HTMLElement;
    for (const node of clone.querySelectorAll("script")) node.remove();
    return {
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

type Round = Judged & { boundMs: number; ratio: number };

/** open_recent and restart: the restart bench's rounds (the app's serving path), with its derived bound. */
function fromRestartBench(scenario: "open_recent" | "restart", arm: Arm): Round[] {
  const mode = scenario === "restart" ? "native-ready" : "reopen";
  const run = Bun.spawnSync(["bun", path.join(webviews, "bench/first-load-after-restart.bench.ts")], {
    cwd: webviews,
    env: {
      ...process.env,
      MODE: mode,
      BOUND: "1",
      ROUNDS: String(ROUNDS),
      TURNS: String(TURNS),
      ...(arm === "stream" ? { RUNNING: "1" } : {}),
    },
    stdout: "pipe",
    stderr: "inherit",
  });
  const out = run.stdout.toString();
  const line = out.split("\n").find((one) => one.startsWith("FIRST_LOAD_JSON "));
  if (run.exitCode !== 0 || !line)
    throw new Error(`first-load-after-restart MODE=${mode} failed:\n${out.slice(-2000)}`);
  type Got = {
    finalFirstPaintMs: number | null;
    shiftFrames: number;
    frames: number;
    boundMs: number | null;
    attachAnsweredMs: number | null;
    shifts: { index: number; why: string }[];
  };
  const got = JSON.parse(line.slice("FIRST_LOAD_JSON ".length)) as Record<string, { rounds: Got[] }>;
  return got[mode]!.rounds.map((r) => {
    if (r.finalFirstPaintMs === null || r.boundMs === null) throw new Error(`MODE=${mode}: a round never settled`);
    // No page can draw data before it exists: when the settled state came after acpmux answered the attach (the
    // running turn moved on since the copy was kept), the bound starts from that answer.
    const ready = r.attachAnsweredMs !== null && r.finalFirstPaintMs > r.attachAnsweredMs ? r.attachAnsweredMs : 0;
    const boundMs = ready + r.boundMs;
    return {
      settledMs: r.finalFirstPaintMs,
      shifts: r.shiftFrames,
      why: r.shifts.slice(0, 5).map((one) => `frame ${one.index} ${one.why}`),
      frames: r.frames,
      boundMs,
      ratio: r.finalFirstPaintMs / Math.max(boundMs, 1),
    };
  });
}
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
    build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false, sourcemap: true } : {}) },
    logLevel: "error",
  });
  // PROFILE keeps the build's source maps beside its profiles, to read their lines back as source.
  const keepMaps = process.env.FAST_CHECKS_OUT ?? process.env.PROFILE_OUT;
  if (PROFILE && keepMaps)
    for (const file of fs.readdirSync(path.join(out, "assets")).filter((name) => name.endsWith(".js.map")))
      fs.copyFileSync(path.join(out, "assets", file), path.join(keepMaps, file));
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
  const base = `http://127.0.0.1:${statics.port}`;
  // `scheme=cmux`, a shipped build's, as every other bench passes: the default `cmux-dev` turns on the dev-only
  // layout-motion audit (devMotionAudit.ts), a box read every frame after each DOM change that Release and NIGHTLY never pay.
  const urlFor = (session: string) =>
    `${base}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${session}`;

  const browser: Browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  const newContext = async () => {
    const context = await browser.newContext({ viewport: VIEWPORT });
    await context.addInitScript(installFrameReader);
    await context.addInitScript(() => {
      (globalThis as { __expSkipRail?: boolean }).__expSkipRail = true;
    });
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
    let profiler: CDPSession | undefined;
    try {
      let page: Page;
      if (scenario === "chat_switch") {
        context = await newContext();
        page = await context.newPage();
        await page.goto(urlFor(A));
        await waitPainted(page, markOf(A));
        await settleIdle(page);
        if (PROFILE) {
          profiler = await context.newCDPSession(page);
          await profiler.send("Profiler.enable");
          await profiler.send("Profiler.setSamplingInterval", { interval: 100 });
          await profiler.send("Profiler.start");
        }
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
        context = await newContext();
        page = await context.newPage();
        await page.goto(urlFor(target));
        await waitPainted(page, markOf(target));
        await settleIdle(page);
        await page.evaluate(() => {
          (window as unknown as { __hidden: boolean }).__hidden = true;
          document.dispatchEvent(new Event("visibilitychange"));
        });
        newTurn(target, arm === "stream");
        await settleIdle(page);
        if (arm === "stream") startStream();
        await page.evaluate(() => {
          (window as unknown as { __hidden: boolean }).__hidden = false;
          const w = window as unknown as { __settle: { start(t0: number): void } };
          w.__settle.start(performance.now());
          document.dispatchEvent(new Event("visibilitychange"));
        });
      } else throw new Error(`${scenario} runs in first-load-after-restart.bench.ts`);
      const read = await framesOf(page, markOf(target));
      stopStream();
      if (profiler) {
        // CDP's Profile leaves samples and timeDeltas optional; a profile with no samples prints as empty.
        const { profile } = await profiler.send("Profiler.stop");
        printProfile(`${scenario}.${arm}`, {
          ...profile,
          samples: profile.samples ?? [],
          timeDeltas: profile.timeDeltas ?? [],
        });
      }
      const judged = judge(read, arm, target);
      if (TRACE) {
        // The timeline to the settled frame: socket traffic, long tasks, and the first frame showing the target.
        const first = read.frames.find(
          (frame) => frame.t >= read.t0 && frame.rows.some((row) => rowOf(row.id, target)),
        );
        const lines = [
          ...read.marks,
          ...(first ? [{ t: first.t, what: "first frame showing the target" }] : []),
          { t: read.t0 + judged.settledMs, what: "settled" },
        ]
          .filter((one) => one.t - read.t0 <= judged.settledMs + 50)
          .sort((x, y) => x.t - y.t);
        console.log(`  ${scenario}.${arm} timeline:`);
        for (const one of lines) console.log(`    +${(one.t - read.t0).toFixed(1)}ms ${one.what}`);
        // What held the settle back: the moves the judge saw, and each frame where the bottom-most row changed.
        for (const reason of judged.why) console.log(`    moved ${reason}`);
        if (process.env.FRAMES === "1" && judged.shifts > 0)
          for (const line of read.vt ?? [])
            console.log(`    vt ${(Number(line.split(" ")[0]) - read.t0).toFixed(1)} ${line}`);
        if (process.env.FRAMES === "1" && judged.shifts > 0)
          for (const frame of read.frames.filter((one) => one.t >= read.t0))
            console.log(
              `    frame +${(frame.t - read.t0).toFixed(1)} st=${frame.scrollTop?.toFixed(1)} ${(frame as { geo?: string }).geo ?? ""} ${frame.rows.map((row) => `${row.id}@${row.top.toFixed(1)}`).join(" ")}`,
            );
        let bottom: string | undefined;
        for (const frame of read.frames) {
          if (frame.t < read.t0) continue;
          const last = frame.rows.reduce<{ id: string; top: number } | undefined>(
            (best, row) => (!best || row.top >= best.top ? row : best),
            undefined,
          )?.id;
          if (last !== bottom) console.log(`    +${(frame.t - read.t0).toFixed(1)}ms bottom row ${last}`);
          bottom = last;
        }
      }
      const copy = await settledCopy(page);
      const boundMs = await boundInPage(page, copy);
      return { ...judged, boundMs, ratio: judged.settledMs / Math.max(boundMs, 1) };
    } finally {
      stopStream();
      await context?.close();
    }
  };

  const report: Record<string, { rounds: Round[] }> = {};
  let score = 0;
  let worst = "";
  for (const scenario of SCENARIOS.filter((name) => !only || only.includes(name)))
    for (const arm of arms) {
      const rounds: Round[] = [];
      if (scenario === "open_recent" || scenario === "restart") rounds.push(...fromRestartBench(scenario, arm));
      else for (let round = 0; round < ROUNDS; round += 1) rounds.push(await one(scenario, arm));
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
