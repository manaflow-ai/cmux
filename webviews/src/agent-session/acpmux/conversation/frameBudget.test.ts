// The chat goes to its minimal motion when its frames miss their budget, and back once they hold it,
// with hysteresis (Leo, 2026-11-09: "at really high loads if it knows it can't performantly perform
// the animation... it just goes into minimal ish mode?").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  createFrameBudget,
  FrameBudgetState,
  HEALTHY_FOR,
  IDLE_FRAMES,
  minimalMotion,
  QUIET_FRAMES,
  rowsMoved,
} from "./frameBudget";
import { motionMode } from "../../../ui/motion/motionMode";

const FRAME = 1000 / 60;

test("healthy frames never go minimal", () => {
  const state = new FrameBudgetState();
  for (let at = 0; at < 3000; at += FRAME) state.frame(FRAME, at);
  expect(state.minimal).toBe(false);
});

test("a second of dropped frames goes minimal, and only HEALTHY_FOR of healthy frames comes back", () => {
  const state = new FrameBudgetState();
  let now = 0;
  // 50 ms frames: each misses about 17 ms past two frames; seven of them cross the bound.
  for (let index = 0; index < 8; index += 1) state.frame(50, (now += 50));
  expect(state.minimal).toBe(true);
  // A short healthy stretch is not enough.
  for (let elapsed = 0; elapsed < HEALTHY_FOR / 2; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(true);
  // One more janky frame starts the healthy count over.
  state.frame(60, (now += 60));
  for (let elapsed = 0; elapsed < HEALTHY_FOR - 100; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(true);
  for (let elapsed = 0; elapsed < 200; elapsed += FRAME) state.frame(FRAME, (now += FRAME));
  expect(state.minimal).toBe(false);
});

test("load the chat keeps meeting goes minimal; one long task or a page back from hidden does not", () => {
  const state = new FrameBudgetState();
  expect(state.frame(30_000, 30_000)).toBe(false);
  expect(state.minimal).toBe(false);
  // One burst (a long chat's first draw): its long task and the frame it held, then frames in budget.
  state.busy(200, 30_100);
  state.frame(250, 30_100);
  for (let at = 30_100; at < 31_000; at += FRAME) state.frame(FRAME, at);
  expect(state.minimal).toBe(false);
  // A long task every 500 ms (the bench's synthetic load): the misses spread over the window.
  state.busy(70, 32_000);
  expect(state.minimal).toBe(false);
  state.busy(70, 32_500);
  expect(state.minimal).toBe(true);
});

test("the chat's mark: its gate moves nothing, the rest of the page moves on, the loop stops when idle, minimal or not, and dispose takes it away", () => {
  const dom = new JSDOM(
    "<!doctype html><html><body><div id=chat class=acpmux-shell><div id=row></div></div><nav id=sidebar></nav></body></html>",
    { pretendToBeVisual: true },
  );
  const doc = dom.window.document;
  const chat = doc.getElementById("chat")!;
  const queue: ((time: number) => void)[] = [];
  const timers: { at: number; callback: () => void }[] = [];
  let now = 0;
  const budget = createFrameBudget(chat, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
    later: (callback, ms) => timers.push({ at: now + ms, callback }) - 1,
    cancelLater: (handle) => {
      timers[handle] = { at: Infinity, callback: () => {} };
    },
  });
  const run = (gap: number) => {
    now += gap;
    const next = queue.splice(0);
    for (const callback of next) callback(now);
    return next.length;
  };
  budget.poke();
  for (let index = 0; index < 10; index += 1) run(60);
  expect(budget.minimal).toBe(true);
  expect(chat.getAttribute("data-chat-motion")).toBe("minimal");
  expect(doc.documentElement.hasAttribute("data-chat-motion")).toBe(false);
  expect(minimalMotion(doc.getElementById("row"))).toBe(true);
  expect(motionMode(doc, doc.getElementById("row"))).toBe("none");
  // The rest of the page keeps its motion (a view swap, the sidebar, depth).
  expect(minimalMotion(doc.getElementById("sidebar"))).toBe(false);
  expect(motionMode(doc, doc.getElementById("sidebar"))).not.toBe("none");
  expect(motionMode(doc)).not.toBe("none");
  // Idle in its minimal motion: the loop stops after IDLE_FRAMES as it does moving, and reads no
  // frames to prove the chat healthy (it read up to 600 of a chat at rest).
  let frames = 0;
  while (run(FRAME) > 0 && frames < 2000) frames += 1;
  expect(frames).toBeLessThan(IDLE_FRAMES);
  expect(queue.length).toBe(0);
  expect(budget.minimal).toBe(true);
  // No work for HEALTHY_FOR: the chat is healthy again, and the mark goes, on one timer.
  expect(timers.filter((timer) => timer.at < Infinity).length).toBe(1);
  now += HEALTHY_FOR;
  for (const timer of timers.splice(0)) if (timer.at <= now) timer.callback();
  expect(budget.minimal).toBe(false);
  expect(chat.hasAttribute("data-chat-motion")).toBe(false);
  // Idle: a poke followed by frames in budget reads QUIET_FRAMES of them past the first and stops.
  budget.poke();
  let idle = 0;
  while (run(FRAME) > 0) idle += 1;
  expect(idle).toBe(QUIET_FRAMES + 1);
  budget.dispose();
  expect(chat.hasAttribute("data-chat-motion")).toBe(false);
});

test("a page that pins its motion is never marked minimal", () => {
  const dom = new JSDOM("<!doctype html><html data-chat-motion=full><body><div id=chat></div></body></html>", {
    pretendToBeVisual: true,
  });
  const doc = dom.window.document;
  const chat = doc.getElementById("chat")!;
  const queue: ((time: number) => void)[] = [];
  let now = 0;
  const budget = createFrameBudget(chat, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
  });
  budget.poke();
  for (let index = 0; index < 20; index += 1) {
    now += 60;
    for (const callback of queue.splice(0)) callback(now);
  }
  expect(budget.minimal).toBe(true);
  expect(chat.hasAttribute("data-chat-motion")).toBe(false);
  expect(motionMode(doc, chat)).not.toBe("none");
  budget.dispose();
  expect(doc.documentElement.getAttribute("data-chat-motion")).toBe("full");
});

test("fresh row objects that change no row are no work; a row that comes, goes or moves on is", () => {
  const rows = [
    { id: "a", version: 1, text: "hi" },
    { id: "b", version: 3, text: "there" },
  ];
  // The pane's commit at rest: the same rows, rebuilt (a switch's second events page).
  const rebuilt = rows.map((row) => ({ ...row }));
  expect(rowsMoved(rows, rows)).toBe(false);
  expect(rowsMoved(rows, rebuilt)).toBe(false);
  expect(rowsMoved([], [])).toBe(false);
  expect(rowsMoved(rows, [...rebuilt, { id: "c", version: 1, text: "new" }])).toBe(true);
  expect(rowsMoved(rows, rebuilt.slice(1))).toBe(true);
  expect(rowsMoved(rows, [rebuilt[0]!, { ...rebuilt[1]!, version: 4 }])).toBe(true);
  expect(rowsMoved(rows, [rebuilt[1]!, rebuilt[0]!])).toBe(true);
});

// A chat at rest after a commit asks for no frames (Leo, 2026-11-12: "infinite everything feels like nothing"):
// the frames after a poke stop once QUIET_FRAMES of them in a row come in budget with no poke between, not
// IDLE_FRAMES later (bench/chat-switch.bench.ts: 51 to 63 of the 5 s at rest after a switch were these frames).
test("a commit at rest reads a few frames, not IDLE_FRAMES; frames that keep missing and load that keeps poking are still read", () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=chat class=acpmux-shell></div></body></html>", {
    pretendToBeVisual: true,
  });
  const chat = dom.window.document.getElementById("chat")!;
  const queue: ((time: number) => void)[] = [];
  let now = 0;
  const budget = createFrameBudget(chat, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
    later: () => -1,
    cancelLater: () => {},
  });
  const run = (gap: number) => {
    now += gap;
    const next = queue.splice(0);
    for (const callback of next) callback(now);
    return next.length;
  };
  const drain = (gap: number) => {
    let frames = 0;
    while (run(gap) > 0 && frames < 2000) frames += 1;
    return frames;
  };
  // A commit, then a chat whose frames hold their budget: the loop ends after QUIET_FRAMES of them.
  budget.poke();
  expect(drain(FRAME)).toBeLessThanOrEqual(QUIET_FRAMES + 1);
  expect(queue.length).toBe(0);
  // Frames that keep missing their budget with no poke (a layout the commit set off): read to IDLE_FRAMES.
  budget.poke();
  expect(drain(40)).toBe(IDLE_FRAMES);
  expect(budget.minimal).toBe(true);
  budget.dispose();

  // Load that keeps coming in bursts, frames in budget between them: each burst's misses count toward the
  // window although the loop stops between bursts, and the chat goes minimal as it did reading every frame.
  const again = createFrameBudget(chat, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
    later: () => -1,
    cancelLater: () => {},
  });
  for (let burst = 0; burst < 4 && !again.minimal; burst += 1) {
    again.poke();
    run(FRAME);
    for (let index = 0; index < 3; index += 1) {
      again.poke();
      run(60);
    }
    drain(FRAME);
  }
  expect(again.minimal).toBe(true);
  again.dispose();
});

// Leo, 2026-11-16, on his NIGHTLY at 4 fps: "it shuold be instant even under load". A loaded chat
// gets a record every few seconds; two idle seconds between them took the minimal mark away, so each
// record came back in on its fade, held invisible through its first frame (entranceClock.ts).
test("a chat that goes idle while its frames still miss stays minimal for its next record", () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=chat class=acpmux-shell></div></body></html>", {
    pretendToBeVisual: true,
  });
  const chat = dom.window.document.getElementById("chat")!;
  const queue: ((time: number) => void)[] = [];
  const timers: { at: number; callback: () => void }[] = [];
  let now = 0;
  const budget = createFrameBudget(chat, {
    now: () => now,
    frame: (callback) => queue.push(callback),
    cancel: () => {},
    later: (callback, ms) => timers.push({ at: now + ms, callback }) - 1,
    cancelLater: (handle) => {
      timers[handle] = { at: Infinity, callback: () => {} };
    },
  });
  const run = (gap: number) => {
    now += gap;
    const next = queue.splice(0);
    for (const callback of next) callback(now);
    return next.length;
  };
  // Records 3 s apart on a page drawing 4 frames a second: each poke reads its frames to IDLE_FRAMES.
  for (let record = 0; record < 3; record += 1) {
    budget.poke();
    let frames = 0;
    while (run(250) > 0 && frames < 200) frames += 1;
    expect(budget.minimal).toBe(true);
    now += 3000;
    for (const timer of timers.splice(0)) if (timer.at <= now) timer.callback();
    // The next record lands minimal: no fade, drawn in the frame it comes.
    expect(chat.getAttribute("data-chat-motion")).toBe("minimal");
  }
  // The load ends: a record whose first frame misses once, then frames in budget. The loop stops on QUIET_FRAMES and
  // the mark goes HEALTHY_FOR later, though that one frame is still in the window (review of #44367).
  budget.poke();
  run(FRAME);
  run(40);
  let settling = 0;
  while (run(FRAME) > 0 && settling < 200) settling += 1;
  expect(settling).toBeLessThan(IDLE_FRAMES);
  now += HEALTHY_FOR;
  for (const timer of timers.splice(0)) if (timer.at <= now) timer.callback();
  expect(chat.hasAttribute("data-chat-motion")).toBe(false);
  budget.dispose();
});
