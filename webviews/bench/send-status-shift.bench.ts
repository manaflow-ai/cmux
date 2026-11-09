// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// What a send moves, from the Return to the reply (Leo, 2026-11-05: "there's the gap between when you send off a
// message versus otherwise, like it's like there's a one-two discontinuity. That's not good."). The production pane
// (a vite build of the pane's dev entry) joins a stand-in acpmux holding four finished turns, idle, the reader at
// the latest row. The reader types a prompt and presses Return; the stand-in answers as acpmux and an agent do:
// the user_message and turn_started at once, then after `--think-ms` (the model's time to its first token) thinking
// in chunks, a tool call that runs and finishes, more thinking, the reply in chunks and the turn's end. Every painted
// frame from the Return to 1 s after the view settles, the bench reads the box of every row in the transcript's view
// and the composer's.
// What it reports, per engine, p50 the median round and p95 the worst:
//   ui.transcript.send.jumps           frames in which a row moved or resized by more than 2 px with no animation
//                                      running the frame before: the layout's own discontinuity, which the eye sees
//                                      as a jump. A glide's steps (a compositor animation, which this sampler sees
//                                      only as often as the main thread paints) are not jumps; a glide that starts
//                                      with a visible move is. Leo's "one-two" is two of these.
//   ui.transcript.send.slot_resizes    how often the running turn's status line changed height between the send and
//                                      the first thinking chunk: a pre-sized slot never does.
//   ui.transcript.send.box_cls         the visible rows' frame-by-frame box diff (src/gallery/shift.ts); the send's own
//                                      glide counts here, so it is a guard, not a target.
//   ui.transcript.send.live_ms         Return to the first frame that paints the running turn's status line.
//   ui.transcript.send.thought_ms      the first thinking chunk's send (stand-in) to the first frame that paints it (its
//                                      words, or the row a live thought draws as).
//   ui.transcript.send.row_ms          Return to the first painted frame that shows the sent prompt's bubble in view.
//   ui.transcript.send.bubble_moves    frames after the bubble first paints in which its top moved more than 2 px in
//                                      the thread (its place in the content, not in the view, which rises while the
//                                      view follows; the thread's own follow glide is left out), or its order among
//                                      the rows changed (a row drawn below it is now above, or the other way). Leo,
//                                      2026-11-09: "i hate the way when i send off a message it seems to move up and
//                                      under your current running tool call or whatever". Target 0.
//   ui.transcript.send.settled_ms      Return to the last frame, before the agent's first output, in which a row in view
//                                      moved or the sent bubble first drew: the send's whole motion, end to end. Leo,
//                                      2026-11-09: "the scroll up is extremely sluggish". Target 150 ms or less.
//   ui.transcript.send.settle_steps    the frames in that span in which a row in view moved: one is the rise in one
//                                      frame; more is a motion in steps (a glide, a settle after it).
//   ui.transcript.send.place_frames    painted frames from the Return to the first one that draws the sent bubble where
//                                      it rests (within 1 px in view). Target 1.
//   ui.transcript.send.live_last_violations  frames in which the running turn's status line (the live zone's row,
//                                      drawn below) is drawn and is not the transcript's last row. Target 0.
// And a log of each jump: its frame, its time since the Return, what moved and by how much.
// Modes, which compose:
//   --mid-turn  the reader sends while a turn already runs, a tool call in flight: the prompt is a steer. The stand-in
//               opens the chat with that turn running (thinking, then a call still running); the steer is recorded at
//               once, the call runs on for `--think-ms` after the send, then ends, the agent reads the steer (acpmux's
//               `steer_read`, and the prompt request answers `steered`), and the turn goes on as above to its end.
//   --load MS   synthetic main-thread load in the page from just before the Return to the round's end: every frame
//               busy-waits MS ms, and a 120 ms long task runs every 500 ms ("everything's just a bit slow rn").
// The mode ("open", "mid-turn", either with "+loadMS") is in the report's header and the JSON; the metric names stay.
//   bun bench/send-status-shift.bench.ts [rounds=3] [--engines chromium,webkit] [--think-ms 1500] [--mid-turn]
//     [--load MS] [--arm NAME] [--chat-motion full|minimal] [--history N] [--json FILE]
//   --history N  the chat holds N finished turns before the send (4 by default): `--history 1000` is a chat of
//               Leo's real size, about 3000 rows (Leo, 2026-11-09: "the scroll up is extremely sluggish").
//   --chat-motion  pins the chat's motion on the page (frameBudget.ts): `full` keeps the frame budget from turning
//               minimal motion on, `minimal` starts in it, to measure the budget's own cost and the minimal mode.
//   --arm NAME  the follow-motion experiment's arm for the page (followMotion.experiment.ts), so one checkout can
//               measure the slim `send` arm against the spring chase (`blocks`); the page's default without it.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { scoreBoxFrames, type BoxFrame } from "../src/gallery/shift";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const ENGINES = (flag("--engines") ?? "chromium,webkit").split(",");
const THINK_MS = Number(flag("--think-ms") ?? 1500);
const JSON_OUT = flag("--json");
const MID_TURN = argv.includes("--mid-turn");
const LOAD_MS = Number(flag("--load") ?? 0);
const ARM = flag("--arm");
const CHAT_MOTION = flag("--chat-motion");
const HISTORY = Number(flag("--history") ?? 4);
/// The flags that take a value: a number after one of them is that value, not the rounds.
const VALUED = new Set(["--engines", "--think-ms", "--json", "--load", "--arm", "--chat-motion", "--history"]);
const ROUNDS = Number(argv.find((arg, index) => /^\d+$/.test(arg) && !VALUED.has(argv[index - 1] ?? "")) ?? 3);
if (
  !Number.isInteger(ROUNDS) ||
  ROUNDS < 1 ||
  !Number.isFinite(LOAD_MS) ||
  !Number.isInteger(HISTORY) ||
  HISTORY < 1 ||
  (CHAT_MOTION !== undefined && CHAT_MOTION !== "full" && CHAT_MOTION !== "minimal") ||
  LOAD_MS < 0 ||
  ENGINES.some((name) => name !== "chromium" && name !== "webkit")
) {
  console.error(
    "usage: bun bench/send-status-shift.bench.ts [rounds=3] [--engines chromium,webkit] [--think-ms N] [--mid-turn] [--load MS] [--arm NAME] [--chat-motion full|minimal] [--history N]",
  );
  process.exit(2);
}
/// What the round sends into, for the report and the JSON: "open" (an idle chat) or "mid-turn", "+loadN" under load.
export const MODE = `${MID_TURN ? "mid-turn" : "open"}${LOAD_MS > 0 ? `+load${LOAD_MS}` : ""}${ARM ? `+arm=${ARM}` : ""}${CHAT_MOTION ? `+${CHAT_MOTION}` : ""}${HISTORY !== 4 ? `+history${HISTORY}` : ""}`;
/// A row that moves more than this in one frame jumped; under it, a step of a motion.
export const JUMP_PX = 2;

const webviews = path.resolve(import.meta.dir, "..");
const SESSION = "0190a000-0000-7000-8000-0000000000e9";
const LIVE = "thinking-live";
const PROMPT = "Find every retry loop and fix the cap";
const THOUGHT = "Looking for every retry loop: the fetch client, the socket reconnect and the upload queue";
/// `--mid-turn`: the turn already running when the reader sends, and its call still in flight.
const RUNNING_PROMPT = "Map where the client backs off";
const RUNNING_THOUGHT = "Searching the client for its backoff helpers first";
const RUNNING_CALL = "t-running";

// ---------- the stand-in acpmux ----------
let status = "idle";
const summary = () => ({
  sessionId: SESSION,
  cwd: "/home/dev/sun",
  title: "Retry policy",
  harness: "claude",
  family: "claude",
  status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: HISTORY,
  updatedAt: Date.now(),
});
const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: body },
});
const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const thought = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const events: Event[] = [];
const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
  const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
  events.push(event);
  return event;
};
for (let turn = 0; turn < HISTORY; turn++) {
  record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
  record("mux", "turn_started", {});
  record(
    "in",
    "agent_message_chunk",
    chunk(
      `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops ` +
        "after five attempts. The fetch tests cover a server that fails twice and then answers.",
    ),
  );
  record("mux", "turn_result", { status: "completed" });
}
const opened = events.length;

function answer(method: string): unknown {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary()] };
    // The history, and with `--mid-turn` the turn running in it (`openRunningTurn`).
    case "_acpmux/attach":
      return { session: summary(), lastSeq: events.length, events: events.slice() };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
}
type Socket = { send(data: string): void };
let socket: Socket | undefined;
const emit = (dir: string, kind: string, msg: Record<string, unknown>) =>
  socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
const changed = () =>
  socket?.send(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
    }),
  );
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
/// When the stand-in sent the turn's first thinking chunk (Date.now()).
let thoughtSentAt = 0;
let turnDone: Promise<void> = Promise.resolve();
/// Whether the pane sent this round's prompt request yet.
let prompted = false;

/// The turn, as acpmux and an agent run it; answers the prompt request when it ends.
async function runTurn(ws: Socket, id: number, promptId: string | undefined) {
  status = "running";
  emit("mux", "user_message", { text: PROMPT, ...(promptId ? { promptId } : {}) });
  emit("mux", "turn_started", {});
  changed();
  await sleep(THINK_MS);
  await work();
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
}

/// `--mid-turn`: the chat opens with a turn running, its call in flight, as another prompt (an earlier one, or one
/// another client sent) left it. Recorded before the page attaches, so the attach carries it.
function openRunningTurn() {
  status = "running";
  record("mux", "user_message", { text: RUNNING_PROMPT, promptId: "p-running" });
  record("mux", "turn_started", {});
  record("in", "agent_thought_chunk", thought(RUNNING_THOUGHT));
  record(
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: RUNNING_CALL,
      title: "rg -n backoff",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "rg -n backoff" },
    }),
  );
}

/// `--mid-turn`: the prompt is a steer into the running turn, as acpmux runs one for Claude Code: its record (steer,
/// waiting) at once; the call in flight runs on `THINK_MS` and ends; the agent reads the steer at its next step
/// (acpmux `steer_read`, and the steer's request answers `steered`); the turn goes on to its end.
async function steerTurn(ws: Socket, id: number, promptId: string | undefined) {
  emit("mux", "user_message", { text: PROMPT, steer: true, ...(promptId ? { promptId } : {}) });
  await sleep(THINK_MS);
  emit(
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: RUNNING_CALL, status: "completed" }),
  );
  await sleep(300);
  if (promptId) emit("mux", "steer_read", { promptId });
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "steered" } }));
  await work();
}

/// The turn's work from its first thinking chunk to its end (shared by both modes).
async function work() {
  thoughtSentAt = Date.now();
  for (const word of THOUGHT.split(" ")) {
    emit("in", "agent_thought_chunk", thought(`${word} `));
    await sleep(40);
  }
  emit(
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: "t-live",
      title: "rg retry",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "rg retry" },
    }),
  );
  await sleep(400);
  emit(
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: "t-live", status: "completed" }),
  );
  await sleep(300);
  emit("in", "agent_thought_chunk", thought("Three loops; each sleeps on its own. "));
  await sleep(300);
  for (const part of [
    "Every retry loop now shares one capped backoff. ",
    "The fetch client, the socket reconnect and the upload queue ",
    "each called their own sleep; they now call `backoff(attempt)`, which stops at eight seconds.",
  ]) {
    emit("in", "agent_message_chunk", chunk(part));
    await sleep(80);
  }
  status = "idle";
  emit("mux", "turn_result", { status: "completed" });
  changed();
}

// ---------- the page side ----------
/// Resolves once the transcript's offset and height have held, with nothing in it animating, for 12 painted frames.
const rest = (page: Page) =>
  page.evaluate(async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const moving = () =>
      document
        .getAnimations()
        .some(
          (animation) =>
            animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
        );
    let last = "";
    for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
      await window.cmuxPaintFrame();
      const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
      held = now === last && !moving() ? held + 1 : 0;
      last = now;
    }
  });

export type Sample = { id: string; kind: string; x: number; y: number; width: number; height: number };
/// A mounted row's place in the thread: `y` from the thread's top, so neither the view's offset nor the thread's
/// follow glide (a translate of the whole thread) moves it; a row's own move (its top, a glide of its own) does.
/// `live`: the running turn's status line (the live zone's row, drawn below); `sent`: the sent prompt's bubble.
export type Placed = { id: string; y: number; height: number; live: boolean; sent: boolean };
export type Frame = {
  at: number;
  rows: Sample[];
  thought: boolean;
  anims: number;
  /** Every mounted row in the thread, in or out of view, top to bottom. */
  order: Placed[];
  /** The sent prompt's bubble is in the view. */
  sentShown: boolean;
};
/// Samples every row box in the transcript's view, and the composer's, once per painted frame, in the view's
/// coordinates, with the wall time (Date.now(), the stand-in's clock) of each.
const startSampling = (page: Page, thoughtText: string) =>
  page.evaluate(
    ({ thoughtText, prompt, liveId }) => {
      const w = window as unknown as { __frames: Frame[]; __stop: () => void };
      w.__frames = [];
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const read = () => {
        const view = scroller.getBoundingClientRect();
        const rows: Sample[] = [];
        for (const row of scroller.querySelectorAll<HTMLElement>("[data-row-id]")) {
          const box = row.getBoundingClientRect();
          if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
          rows.push({
            id: row.dataset.rowId!,
            kind: (row.firstElementChild?.className || row.className || "").toString().split(" ")[0] ?? "",
            x: box.x - view.x,
            y: box.y - view.y,
            width: box.width,
            height: box.height,
          });
        }
        const composer = document.querySelector(".acpmux-composer")?.getBoundingClientRect();
        if (composer)
          rows.push({
            id: "composer",
            kind: "composer",
            x: composer.x - view.x,
            y: composer.y - view.y,
            width: composer.width,
            height: composer.height,
          });
        // Running finite animations (the follow glide, a fold): their frames are motion, not layout jumps.
        const anims = document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          ).length;
        // Every mounted row's place in the thread, and which is the sent bubble (the row holding the prompt's text).
        const thread = scroller.querySelector<HTMLElement>(".acpmux-thread") ?? scroller;
        const origin = thread.getBoundingClientRect().top;
        const order: Placed[] = [];
        let sentShown = false;
        for (const row of thread.querySelectorAll<HTMLElement>(".acpmux-row")) {
          const box = row.getBoundingClientRect();
          if (box.height <= 0) continue;
          const id = row.dataset.rowId ?? "";
          const sent = (row.textContent ?? "").includes(prompt);
          if (sent && box.bottom > view.top && box.top < view.bottom) sentShown = true;
          order.push({
            id,
            y: box.top - origin,
            height: box.height,
            live: id === liveId || row.classList.contains("acpmux-row--below"),
            sent,
          });
        }
        order.sort((a, b) => a.y - b.y);
        w.__frames.push({
          at: Date.now(),
          rows,
          thought: scroller.innerText.includes(thoughtText),
          anims,
          order,
          sentShown,
        });
      };
      read();
      w.__stop = window.cmuxAfterPaint(() => {
        read();
      });
    },
    { thoughtText, prompt: PROMPT, liveId: LIVE },
  );

/// `--load MS`: from now on every frame busy-waits `ms` and a 120 ms long task runs every 500 ms, until `stopLoad`.
const startLoad = (page: Page, ms: number) =>
  page.evaluate((ms) => {
    const w = window as unknown as { __stopLoad?: () => void };
    const busy = (wait: number) => {
      const until = performance.now() + wait;
      while (performance.now() < until) {
        // Hold the main thread.
      }
    };
    let running = true;
    const frame = () => {
      if (!running) return;
      busy(ms);
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
    const long = setInterval(() => busy(120), 500);
    w.__stopLoad = () => {
      running = false;
      clearInterval(long);
    };
  }, ms);
const stopLoad = (page: Page) => page.evaluate(() => (window as unknown as { __stopLoad?: () => void }).__stopLoad?.());
const stopSampling = (page: Page) =>
  page.evaluate(() => {
    const w = window as unknown as { __frames: Frame[]; __stop: () => void };
    w.__stop();
    const box = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
    return { frames: w.__frames, view: { width: box.width, height: box.height } };
  });

export type Jump = { frame: number; ms: number; id: string; kind: string; dx: number; dy: number; dh: number };
export type Round = {
  jumps: Jump[];
  boxCls: number;
  liveMs: number | null;
  userMs: number | null;
  thoughtMs: number | null;
  liveHeights: number[];
  /** How often the live line changed height between the send and the first thinking chunk: its slot. */
  slotResizes: number;
  /** The harness's painted-frame interval, p95 (ms): how sparse the sampler was. */
  frameP95: number;
  /** The frames of the send's first second, each row as `id y+h`, for reading what moved. */
  trace: string[];
  /** Return to the first frame that shows the sent bubble in view. */
  rowMs: number | null;
  /** The frames after it first painted in which the sent bubble moved in the thread or changed order. */
  bubbleMoves: BubbleMove[];
  /** The frames in which the running turn's status line is drawn and is not the last row. */
  liveLast: LiveLast[];
  /** Return to the send's last motion before the agent's first output (ms). */
  settledMs: number | null;
  /** Frames in that span in which a row in view moved. */
  settleSteps: number;
  /** Painted frames from the Return to the first that draws the bubble where it rests. */
  placeFrames: number | null;
};
/// A frame in which the sent bubble moved in the thread by `dy`, or rows went from one side of it to the other
/// (`crossed`: the rows that did).
export type BubbleMove = { frame: number; ms: number; dy: number; crossed: string[] };
/// A frame in which the status line was not the last row: `last` was under it.
export type LiveLast = { frame: number; ms: number; last: string };

/// The sent bubble's moves after it first painted (pure): see `BubbleMove`. A frame that has the bubble unmounted
/// (scrolled out of the mounted range) is skipped; the next frame that has it is compared with the last that did.
export function bubbleMoves(frames: Frame[], sentAt: number): BubbleMove[] {
  const moves: BubbleMove[] = [];
  const start = frames.findIndex((frame) => frame.sentShown);
  if (start < 0) return moves;
  let was: { frame: Frame; bubble: Placed } | undefined;
  for (let index = start; index < frames.length; index++) {
    const frame = frames[index]!;
    const bubble = frame.order.find((row) => row.sent);
    if (!bubble) continue;
    if (was) {
      const before = was.bubble.y;
      const dy = bubble.y - before;
      const above = new Map(was.frame.order.filter((row) => !row.sent).map((row) => [row.id, row.y < before]));
      const crossed: string[] = [];
      for (const row of frame.order) {
        const wasAbove = row.sent ? undefined : above.get(row.id);
        if (wasAbove === undefined) continue;
        const isAbove = row.y < bubble.y;
        if (wasAbove !== isAbove) crossed.push(row.id);
      }
      if (Math.abs(dy) > JUMP_PX || crossed.length)
        moves.push({ frame: index, ms: frame.at - sentAt, dy: Math.round(dy), crossed });
    }
    was = { frame, bubble };
  }
  return moves;
}

/// The frames in which the running turn's status line is drawn and another row is drawn under it (pure).
export function liveLastViolations(frames: Frame[], sentAt: number): LiveLast[] {
  const out: LiveLast[] = [];
  for (const [index, frame] of frames.entries()) {
    const last = frame.order.at(-1);
    if (last && !last.live && frame.order.some((row) => row.live))
      out.push({ frame: index, ms: frame.at - sentAt, last: last.id });
  }
  return out;
}

/// The round's numbers (pure). `sentAt` is the Return's wall time, `thoughtAt` the first thinking chunk's.
export function measure(
  frames: Frame[],
  view: { width: number; height: number },
  sentAt: number,
  thoughtAt: number,
  rows0: Set<string>,
): Round {
  const ids = new Map<string, number>();
  const boxFrames: BoxFrame[] = frames.map(
    (frame) =>
      new Map(
        frame.rows.map((row) => {
          if (!ids.has(row.id)) ids.set(row.id, ids.size + 1);
          return [ids.get(row.id)!, { box: row, label: `${row.kind} ${row.id}` }] as const;
        }),
      ),
  );
  const box = scoreBoxFrames(boxFrames, view, { restedAtStart: true });
  // A jump: a row seen the frame before moved (or resized) by more than JUMP_PX at once. One jump per frame:
  // the row that moved most.
  const jumps: Jump[] = [];
  for (let index = 1; index < frames.length; index++) {
    // A move while an animation already ran in the frame before is that animation's step (a glide on the
    // compositor, sampled only as often as the main thread paints); a move with none running is the layout's own.
    if (frames[index - 1]!.anims > 0) continue;
    const before = new Map(frames[index - 1]!.rows.map((row) => [row.id, row]));
    let worst: Jump | undefined;
    for (const row of frames[index]!.rows) {
      const was = before.get(row.id);
      if (!was) continue;
      const dx = row.x - was.x;
      const dy = row.y - was.y;
      const dh = row.height - was.height;
      const size = Math.max(Math.abs(dx), Math.abs(dy), Math.abs(dh));
      if (size <= JUMP_PX) continue;
      if (!worst || size > Math.max(Math.abs(worst.dx), Math.abs(worst.dy), Math.abs(worst.dh)))
        worst = {
          frame: index,
          ms: frames[index]!.at - sentAt,
          id: row.id,
          kind: row.kind,
          dx: Math.round(dx),
          dy: Math.round(dy),
          dh: Math.round(dh),
        };
    }
    if (worst) jumps.push(worst);
  }
  const first = (test: (frame: Frame) => boolean) => frames.find(test);
  const live = first((frame) => frame.rows.some((row) => row.id === LIVE));
  const user = first((frame) =>
    frame.rows.some((row) => !rows0.has(row.id) && row.id !== LIVE && row.id !== "composer"),
  );
  // The thought's row: the first row after the send that is neither the sent prompt nor the line (a live thought
  // draws as its one-line row, its words inside it).
  const sentRow = user?.rows.find((row) => !rows0.has(row.id) && row.id !== LIVE && row.id !== "composer")?.id;
  const shown = first(
    (frame) =>
      frame.at >= thoughtAt &&
      (frame.thought || frame.rows.some((row) => !rows0.has(row.id) && ![LIVE, "composer", sentRow].includes(row.id))),
  );
  const liveHeights = [
    ...new Set(
      frames.flatMap((frame) => frame.rows.filter((row) => row.id === LIVE).map((row) => Math.round(row.height))),
    ),
  ];
  const bubble = first((frame) => frame.sentShown);
  // The order rules hold while the turn runs: its end folds the turn's work in one motion and the live line
  // leaves for the footer, which moves rows by design. The running frames end where the turn's footer draws.
  const earlier = new Set(frames[0]?.order.map((row) => row.id) ?? []);
  const ended = frames.findIndex((frame) =>
    frame.order.some((row) => row.id.startsWith("summary-") && !earlier.has(row.id)),
  );
  const running = ended < 0 ? frames : frames.slice(0, ended);
  // The send's own motion: from the Return to the agent's first output (the first thought, or the think time), the
  // frames in which a row in view moved, and where the bubble rests at the span's end.
  const quietUntil = thoughtAt || sentAt + THINK_MS;
  const from = frames.findIndex((frame) => frame.at >= sentAt);
  const span = from < 0 ? [] : frames.slice(Math.max(0, from - 1)).filter((frame) => frame.at < quietUntil);
  // The frame before the Return, the first one moves are read against; not one of the send's own.
  const opening = from > 0 ? 1 : 0;
  const sentIn = (frame: Frame) => {
    const id = frame.order.find((row) => row.sent)?.id;
    return id === undefined ? undefined : frame.rows.find((row) => row.id === id);
  };
  let settledAt: number | undefined;
  let settleSteps = 0;
  for (let index = 1; index < span.length; index++) {
    const before = new Map(span[index - 1]!.rows.map((row) => [row.id, row]));
    // The transcript's rows: the composer's card shrinking as it lets the prompt go is the composer's own.
    const moved = span[index]!.rows.some((row) => {
      if (row.id === "composer") return false;
      const was = before.get(row.id);
      return was !== undefined && (Math.abs(row.y - was.y) > 0.5 || Math.abs(row.height - was.height) > 0.5);
    });
    if (moved) {
      settleSteps += 1;
      settledAt = span[index]!.at;
    }
  }
  const sent = span.slice(opening);
  const firstSent = sent.find((frame) => sentIn(frame) !== undefined);
  if (firstSent && (settledAt === undefined || firstSent.at > settledAt)) settledAt = firstSent.at;
  const rest = sent.length ? sentIn(sent.at(-1)!) : undefined;
  const placedAt = rest ? sent.findIndex((frame) => Math.abs((sentIn(frame)?.y ?? Number.NaN) - rest.y) <= 1) : -1;
  return {
    settledMs: settledAt === undefined ? null : settledAt - sentAt,
    settleSteps,
    placeFrames: placedAt < 0 ? null : placedAt + 1,
    rowMs: bubble ? bubble.at - sentAt : null,
    bubbleMoves: bubbleMoves(running, sentAt),
    liveLast: liveLastViolations(running, sentAt),
    jumps,
    boxCls: box.score,
    liveMs: live ? live.at - sentAt : null,
    userMs: user ? user.at - sentAt : null,
    thoughtMs: shown && thoughtAt ? shown.at - thoughtAt : null,
    liveHeights,
    slotResizes: (() => {
      const heights = frames
        .filter((frame) => !thoughtAt || frame.at < thoughtAt)
        .map((frame) => frame.rows.find((row) => row.id === LIVE)?.height)
        .filter((height): height is number => height !== undefined)
        .map(Math.round);
      return heights.filter((height, index) => index > 0 && height !== heights[index - 1]).length;
    })(),
    frameP95: (() => {
      const gaps = frames
        .slice(1)
        .map((frame, index) => frame.at - frames[index]!.at)
        .sort((a, b) => a - b);
      return gaps.length ? gaps[Math.floor(0.95 * (gaps.length - 1))]! : 0;
    })(),
    // Up to 800 ms past the first thought, the frames that differ from the one before.
    trace: frames
      .filter((frame) => frame.at - (thoughtAt || sentAt + 1000) <= 800)
      .map(
        (frame) =>
          `a${frame.anims}${frame.thought ? " T" : ""} ` +
          frame.rows.map((row) => `${row.id} ${Math.round(row.y)}+${Math.round(row.height)}`).join(" | "),
      )
      .map((line, index) => `+${frames[index]!.at - sentAt} ${line}`)
      .filter((line, index, all) => index === 0 || line.replace(/^\S+ /, "") !== all[index - 1]!.replace(/^\S+ /, "")),
  };
}

async function round(browser: Browser, url: string): Promise<Round> {
  events.length = opened;
  status = "idle";
  thoughtSentAt = 0;
  prompted = false;
  if (MID_TURN) openRunningTurn();
  const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  try {
    await installPaintedFrames(page);
    if (ARM)
      await page.addInitScript((arm) => {
        (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "follow-motion": arm };
      }, ARM);
    // The product's frame budget runs as in the app (frameBudget.ts keeps an automated page's motion
    // unless it asks): the bench measures what a person sees.
    await page.addInitScript(() => Object.assign(window, { cmuxFrameBudget: "on" }));
    if (CHAT_MOTION)
      await page.addInitScript((mode) => {
        const pin = () => document.documentElement?.setAttribute("data-chat-motion", mode);
        pin();
        document.addEventListener("readystatechange", pin, { once: true });
      }, CHAT_MOTION);
    await page.goto(url);
    await page.locator(".acpmux-composer-prompt").waitFor({ timeout: 60_000 });
    await page.locator("[data-row-id]").first().waitFor({ timeout: 60_000 });
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(PROMPT);
    await page.mouse.move(0, 0);
    await rest(page);
    await page.waitForTimeout(400);
    const rows0 = new Set(
      await page
        .locator("[data-row-id]")
        .evaluateAll((nodes) => nodes.map((node) => (node as HTMLElement).dataset.rowId!)),
    );
    await startSampling(page, THOUGHT.split(" ").slice(0, 4).join(" "));
    if (LOAD_MS > 0) await startLoad(page, LOAD_MS);
    const sentAt = Date.now();
    await page.keyboard.press("Enter");
    await sleep(THINK_MS + 200);
    // Under load the prompt request can come late: wait for it, so `turnDone` is this round's turn.
    const until = Date.now() + 15_000;
    while (!prompted && Date.now() < until) await sleep(20);
    if (!prompted) throw new Error("the pane sent no prompt request");
    await turnDone;
    await rest(page);
    await page.waitForTimeout(1000);
    await rest(page);
    if (LOAD_MS > 0) await stopLoad(page);
    const { frames, view } = await stopSampling(page);
    return measure(frames, view, sentAt, thoughtSentAt, rows0);
  } finally {
    await page.close();
  }
}

if (import.meta.main) {
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: { _meta?: { acpmux?: { promptId?: string; steer?: boolean } } };
          };
          if (message.method === "_acpmux/attach") socket = ws;
          if (message.method === "session/prompt" && message.id !== undefined) {
            const meta = message.params?._meta?.acpmux;
            prompted = true;
            if (MID_TURN && meta?.steer !== true)
              console.log("send-status-shift: the pane sent the mid-turn prompt as no steer; the stand-in steers it");
            turnDone = MID_TURN ? steerTurn(ws, message.id, meta?.promptId) : runTurn(ws, message.id, meta?.promptId);
            return;
          }
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(["stand-in acpmux", () => daemon.stop(true)]);
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-status-shift-bench-"));
    releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
    const builtAt = performance.now();
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    console.log(`send-status-shift: pane built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
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
    const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${SESSION}`;

    let failed = 0;
    const report: Record<string, Round[]> = {};
    for (const engine of ENGINES) {
      const isChromium = engine === "chromium";
      let browser: Browser;
      try {
        browser = isChromium
          ? await chromium.launch({
              ...(process.env.CMUX_CHROME_HEADLESS_SHELL
                ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
                : { channel: "chrome" }),
              headless: true,
            })
          : await webkit.launch({ headless: true });
      } catch (error) {
        failed += 1;
        console.log(
          `send-status-shift: ${engine} FAILED to launch: ${error instanceof Error ? error.message : String(error)}`,
        );
        continue;
      }
      releases.push([engine, () => browser.close()]);
      const rounds: Round[] = [];
      try {
        for (let index = 0; index < ROUNDS; index++) rounds.push(await round(browser, url));
      } catch (error) {
        failed += 1;
        console.log(`send-status-shift: ${engine} FAILED: ${error instanceof Error ? error.message : String(error)}`);
      }
      if (!rounds.length) continue;
      report[engine] = rounds;
      const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) / 2)]!;
      const stat = (values: number[]) => ({ p50: median(values), p95: Math.max(...values) });
      console.log(
        `send-status-shift: ${engine}, ${rounds.length} rounds, think ${THINK_MS} ms (p50 median, p95 worst)`,
      );
      console.log(
        "round | jumps | slot resizes | box cls | user ms | live ms | thought ms | live heights | frame p95 ms",
      );
      for (const [index, r] of rounds.entries())
        console.log(
          `${index + 1} | ${r.jumps.length} | ${r.slotResizes} | ${r.boxCls.toFixed(4)} | ${r.userMs} | ${r.liveMs} | ${r.thoughtMs} | ${r.liveHeights.join(",")} | ${r.frameP95}`,
        );
      for (const jump of rounds.at(-1)!.jumps)
        console.log(
          `  jump frame ${jump.frame} +${jump.ms} ms ${jump.kind} ${jump.id} dx ${jump.dx} dy ${jump.dy} dh ${jump.dh}`,
        );
      if (process.env.SEND_SHIFT_TRACE) for (const line of rounds.at(-1)!.trace) console.log(`  ${line}`);
      console.log(`send-status-shift: ${engine}, mode ${MODE}`);
      console.log("round | row ms | bubble moves | live-last violations | settled ms | settle steps | place frames");
      for (const [index, r] of rounds.entries())
        console.log(
          `${index + 1} | ${r.rowMs} | ${r.bubbleMoves.length} | ${r.liveLast.length} | ${r.settledMs} | ${r.settleSteps} | ${r.placeFrames}`,
        );
      for (const move of rounds.at(-1)!.bubbleMoves)
        console.log(
          `  bubble frame ${move.frame} +${move.ms} ms dy ${move.dy}${move.crossed.length ? ` crossed ${move.crossed.join(",")}` : ""}`,
        );
      for (const each of rounds.at(-1)!.liveLast)
        console.log(`  live-last frame ${each.frame} +${each.ms} ms under it: ${each.last}`);
      const name = `ui.transcript.send${isChromium ? "" : ".webkit"}`;
      perfRow({
        name: `${name}.settled_ms`,
        ...stat(rounds.map((r) => r.settledMs ?? 9999)),
        unit: "ms",
        target: 150,
        floor: 17,
      });
      perfRow({
        name: `${name}.settle_steps`,
        ...stat(rounds.map((r) => r.settleSteps)),
        unit: "count",
        target: 1,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.place_frames`,
        ...stat(rounds.map((r) => r.placeFrames ?? 999)),
        unit: "count",
        target: 1,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.jumps`,
        ...stat(rounds.map((r) => r.jumps.length)),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.slot_resizes`,
        ...stat(rounds.map((r) => r.slotResizes)),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.box_cls`,
        ...stat(rounds.map((r) => Math.round(r.boxCls * 1e4) / 1e4)),
        unit: "score",
        target: 0.01,
        floor: 0.001,
      });
      perfRow({
        name: `${name}.live_ms`,
        ...stat(rounds.map((r) => r.liveMs ?? 9999)),
        unit: "ms",
        target: 17,
        floor: 17,
      });
      perfRow({
        name: `${name}.thought_ms`,
        ...stat(rounds.map((r) => r.thoughtMs ?? 9999)),
        unit: "ms",
        target: 34,
        floor: 17,
      });
      perfRow({
        name: `${name}.row_ms`,
        ...stat(rounds.map((r) => r.rowMs ?? 9999)),
        unit: "ms",
        target: 17,
        floor: 17,
      });
      perfRow({
        name: `${name}.bubble_moves`,
        ...stat(rounds.map((r) => r.bubbleMoves.length)),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.live_last_violations`,
        ...stat(rounds.map((r) => r.liveLast.length)),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
    }
    if (JSON_OUT)
      fs.writeFileSync(
        JSON_OUT,
        JSON.stringify({ thinkMs: THINK_MS, mode: MODE, midTurn: MID_TURN, loadMs: LOAD_MS, report }, null, 2),
      );
    if (failed) process.exitCode = 1;
  } finally {
    await release();
  }
}
