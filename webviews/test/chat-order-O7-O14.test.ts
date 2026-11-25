// Ordering map O7-O14 (design/chat-animation-ordering-map.md), the turn-end fold's overlaps, as a
// jsdom frame test: every animation the fold plays is recorded with its delay, duration and keyframes.
// Leo, 2026-11-21: "some animations i think are still a bit... off. like, you finish some sort of
// tool call, things happen, things fold, stuff comes in at different times".
//
// - O7  a row arriving under the kept row while the fold plays fades at its final place
// - O8  a text row that brings its own entrance (`--message-enter`) keeps only that entrance
// - O9  a second turn end settles the first fold (animations finished, copies gone) before it plays
// - O10 a first frame that paints late re-arms the fold's backstop from that frame, nothing is finished
// - O11 a longer move before the first frame flattens the curve and restarts the clock (`grew`)
// - O12 a later pass joins on the running clock (negative delay), never on a new one
// - O13 no live line mounted (reader scrolled away): no capture, nothing plays
// - O14 a held Worked closing on return: the capture is taken without a live line and plays the fold
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { captureTurnEnd, playTurnEnd, settleTurnEnd } from "../src/agent-session/acpmux/conversation/turnEndFold";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

type Played = {
  node: HTMLElement;
  keyframes: Keyframe[];
  delay: number;
  duration: number;
  easing: string;
  finished: number;
  cancelled: number;
};

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind,
});

const realNow = performance.now.bind(performance);
const realSetTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;
let skew = 0;
afterEach(() => {
  performance.now = realNow;
  globalThis.setTimeout = realSetTimeout;
  globalThis.clearTimeout = realClearTimeout;
  skew = 0;
});

/// A page whose rows are laid out by their inline top and height, with the frames and timers the test
/// runs by hand, recording every animation.
function page() {
  const dom = new JSDOM("<!doctype html><main></main>", {
    pretendToBeVisual: true,
  });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  // The thread stands in for the scroller here, so it needs a view of its own: `captureTurnEnd`
  // plays nothing whose rows all sit outside the scroller's box, and jsdom gives every box its
  // inline `top`/`height`, which a bare <main> leaves at zero (a view of no height sees nothing).
  thread.style.height = "600px";
  const proto = dom.window.HTMLElement.prototype;
  Object.defineProperty(proto, "offsetTop", {
    get() {
      return Number.parseFloat(this.style.top) || 0;
    },
  });
  Object.defineProperty(proto, "offsetHeight", {
    get() {
      return Number.parseFloat(this.style.height) || 0;
    },
  });
  proto.getBoundingClientRect = function () {
    const top = this.offsetTop;
    const height = this.offsetHeight;
    return {
      top,
      bottom: top + height,
      height,
      left: 0,
      right: 100,
      width: 100,
      x: 0,
      y: top,
      toJSON() {},
    };
  };
  const played: Played[] = [];
  proto.animate = function (keyframes, options) {
    const timing = (typeof options === "number" ? { duration: options } : (options ?? {})) as KeyframeAnimationOptions;
    const entry: Played = {
      node: this,
      keyframes: keyframes as Keyframe[],
      delay: Number(timing.delay ?? 0),
      duration: Number(timing.duration ?? 0),
      easing: String(timing.easing ?? ""),
      finished: 0,
      cancelled: 0,
    };
    played.push(entry);
    return {
      cancel() {
        entry.cancelled += 1;
      },
      finish() {
        entry.finished += 1;
      },
      onfinish: null,
      oncancel: null,
    } as unknown as Animation;
  };
  // The first frame is the test's to run; the page's clock is performance.now plus `skew`.
  const frames: FrameRequestCallback[] = [];
  dom.window.requestAnimationFrame = ((callback: FrameRequestCallback) => frames.push(callback)) as never;
  dom.window.cancelAnimationFrame = (() => {}) as never;
  performance.now = () => realNow() + skew;
  const timers: { delay: number; handle: unknown }[] = [];
  const cleared: unknown[] = [];
  globalThis.setTimeout = ((fn: () => void, delay?: number) => {
    const handle = realSetTimeout(fn, delay);
    if ((delay ?? 0) >= 200) timers.push({ delay: delay ?? 0, handle });
    return handle;
  }) as never;
  globalThis.clearTimeout = ((handle: never) => {
    cleared.push(handle);
    return realClearTimeout(handle);
  }) as never;
  const draw = (id: string, kind: string, top: number, height: number, extra = "") => {
    const node = dom.window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind} ${extra}`.trim();
    node.dataset.rowId = id;
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    node.textContent = `${kind} ${id}`;
    thread.append(node);
    return node;
  };
  const runFrame = () => {
    const due = frames.splice(0);
    for (const callback of due) callback(realNow() + skew);
  };
  /// Lets the thread's MutationObserver deliver.
  const observed = async () => {
    await Promise.resolve();
    await Promise.resolve();
  };
  return { dom, thread, played, draw, runFrame, observed, timers, cleared };
}

/// The usual turn end: work and the live line over the reply, then the header and the reply.
function endOfTurn(p: ReturnType<typeof page>) {
  p.draw("working-u", "working", 0, 34);
  p.draw("work", "activity", 34, 60);
  p.draw("answer", "assistant", 94, 50);
  p.draw(LIVE_THINKING, "thinking", 144, 22);
  const capture = captureTurnEnd(p.thread, p.thread, [row("worked-u", "worked"), row("answer")], "chat")!;
  expect(capture).toBeDefined();
  p.thread.replaceChildren();
  p.draw("worked-u", "worked", 100, 34);
  p.draw("answer", "assistant", 134, 50);
  return capture;
}

const translates = (entries: Played[]) => entries.filter((e) => e.keyframes.some((f) => f.translate !== undefined));
const opacities = (entries: Played[]) =>
  entries.filter((e) => e.keyframes.some((f) => f.opacity !== undefined) && !e.keyframes.some((f) => f.translate));

test("O7: a row arriving under the kept row while the fold plays fades at its final place", async () => {
  const p = page();
  const capture = endOfTurn(p);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    const before = p.played.length;
    // The next turn's line under the reply, placed while the fold plays.
    const next = p.draw("next-line", "notice", 184, 22);
    await p.observed();
    const mine = p.played.slice(before).filter((e) => e.node === next);
    // The row is already laid out at its final top. It must not ride the kept reply's fold offset.
    const slide = translates(mine);
    expect(slide.length).toBe(0);
    expect(opacities(mine).length).toBe(1);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O8: a text row with its own entrance stays at its final place; its entrance is its only fade", async () => {
  const p = page();
  const capture = endOfTurn(p);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    const before = p.played.length;
    const next = p.draw("next-reply", "assistant", 184, 40, "acpmux-row--message-enter");
    await p.observed();
    const mine = p.played.slice(before).filter((e) => e.node === next);
    expect(translates(mine).length).toBe(0);
    // No kept row crosses its place (the reply above lands at 184, its top): the fold plays nothing on
    // it, so it has one fade, its own entrance, never a second one from the fold (cmux#48689 review).
    expect(opacities(mine).length).toBe(0);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O8b: a row with its own entrance holds at no ink while a kept row slides through its place", () => {
  const p = page();
  // The header was drawn far below its place (a long turn's work above it folds away): it slides up
  // through the place of the reply that first mounts in the settle snapshot.
  p.draw("working-u", "working", 0, 34);
  p.draw("work", "activity", 34, 260);
  p.draw(LIVE_THINKING, "thinking", 294, 22);
  p.draw("worked-u", "worked", 320, 34);
  const capture = captureTurnEnd(p.thread, p.thread, [row("worked-u", "worked"), row("answer")], "chat")!;
  p.thread.replaceChildren();
  p.draw("worked-u", "worked", 100, 34);
  const reply = p.draw("answer", "assistant", 134, 50, "acpmux-row--message-enter");
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    const mine = p.played.filter((e) => e.node === reply);
    expect(translates(mine).length).toBe(0);
    const hold = opacities(mine);
    expect(hold.length).toBe(1);
    expect(hold[0]!.keyframes[0]!.opacity).toBe(0);
    // Past the exit lead by the time the header takes to clear the reply's box.
    const lead = opacities(p.played.filter((e) => e.node !== reply)).reduce((ms, e) => Math.max(ms, e.duration), 0);
    expect(hold[0]!.delay).toBeGreaterThan(lead + 20);
    // The backstop waits for the held fade's end (its delay and length), not the move's alone.
    expect(p.timers.at(-1)!.delay).toBeGreaterThanOrEqual(hold[0]!.delay + hold[0]!.duration);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O9: a second turn end settles the first fold at once, then plays its own", () => {
  const p = page();
  const first = playTurnEnd(p.thread, endOfTurn(p), "chat")!;
  expect(first.animations.size).toBeGreaterThan(0);
  expect(first.copies.size).toBeGreaterThan(0);
  const firstCopies = [...first.copies];
  const firstPlayed = p.played.slice();
  expect(p.thread.hasAttribute("data-turn-end-folding")).toBe(true);
  // VirtualTranscript's layout effect: `settleTurnEnd(host, turnEnd.current)` before `playTurnEnd`.
  settleTurnEnd(p.thread, first);
  for (const entry of firstPlayed) expect(entry.finished).toBe(1);
  expect(first.animations.size).toBe(0);
  expect(first.copies.size).toBe(0);
  for (const copy of firstCopies) expect(p.thread.contains(copy)).toBe(false);
  expect(p.thread.hasAttribute("data-turn-end-folding")).toBe(false);
  // The next turn ends in the same thread: a fold of its own, on fresh animations.
  p.thread.replaceChildren();
  p.draw("working-v", "working", 200, 34);
  p.draw("work-2", "activity", 234, 60);
  p.draw("answer-2", "assistant", 294, 50);
  p.draw(LIVE_THINKING, "thinking", 344, 22);
  const capture = captureTurnEnd(p.thread, p.thread, [row("worked-v", "worked"), row("answer-2")], "chat")!;
  p.thread.replaceChildren();
  p.draw("worked-v", "worked", 300, 34);
  p.draw("answer-2", "assistant", 334, 50);
  const second = playTurnEnd(p.thread, capture, "chat")!;
  try {
    expect(second.animations.size).toBeGreaterThan(0);
    for (const entry of firstPlayed) expect(entry.finished).toBe(1);
    expect(p.thread.hasAttribute("data-turn-end-folding")).toBe(true);
  } finally {
    settleTurnEnd(p.thread, second);
    p.dom.window.close();
  }
});

test("O10: a first frame that paints late re-arms the backstop from that frame; nothing is finished early", () => {
  const p = page();
  const capture = endOfTurn(p);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    expect(p.timers.length).toBe(1);
    const backstop = p.timers[0]!;
    // Longer than the settle itself: the move plus the exit lead plus 50 ms of slack.
    expect(backstop.delay).toBeGreaterThan(50);
    // A busy main thread paints the first frame 130 ms after the swap (entranceClock.ts).
    skew = 130;
    p.runFrame();
    expect(p.timers.length).toBe(2);
    // The old backstop (swap + D, 100 ms short of the move's end) is gone; the new one counts D from the frame.
    expect(p.cleared).toContain(backstop.handle);
    expect(p.timers[1]!.delay).toBe(backstop.delay);
    expect(fold.timer).toBe(p.timers[1]!.handle as never);
    // Nothing was finished (jumped to its end) on the way.
    for (const entry of p.played) expect(entry.finished).toBe(0);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O11: a longer move found before the first frame flattens the curve and restarts the clock", async () => {
  const p = page();
  const capture = endOfTurn(p);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    const first = translates(p.played.filter((e) => e.node.dataset.rowId === "answer"));
    expect(first.length).toBe(1);
    const easing = first[0]!.easing;
    const timersBefore = p.timers.length;
    // Rows the virtualizer mounts above after the swap: the reply is placed 300 px lower than first read.
    p.thread.querySelector<HTMLElement>('[data-row-id="answer"]')!.style.top = "434px";
    await p.observed();
    const restarted = translates(p.played.filter((e) => e.node.dataset.rowId === "answer"));
    expect(restarted.length).toBeGreaterThan(1);
    expect(first[0]!.cancelled).toBe(1);
    const latest = restarted.at(-1)!;
    expect(latest.easing).not.toBe(easing);
    // Still the settle's length, never a crawl.
    expect(latest.duration).toBe(first[0]!.duration);
    expect(latest.keyframes[0]!.translate).toBe("0 -340px");
    // The backstop moves out with the clock.
    expect(p.timers.length).toBeGreaterThan(timersBefore);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O12: a pass after the first frames joins on the running clock, part way in, on the same curve", async () => {
  const p = page();
  const capture = endOfTurn(p);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    p.runFrame();
    const first = translates(p.played.filter((e) => e.node.dataset.rowId === "answer"))[0]!;
    // 100 ms into the fold, past the window in which the curve may still flatten (GROW_WINDOW_MS).
    skew = 100;
    p.thread.querySelector<HTMLElement>('[data-row-id="answer"]')!.style.top = "144px";
    await p.observed();
    const all = translates(p.played.filter((e) => e.node.dataset.rowId === "answer"));
    expect(all.length).toBe(2);
    const joined = all[1]!;
    expect(first.cancelled).toBe(1);
    // Starts in the past: the animation begins part way through the fold's clock.
    expect(joined.delay).toBeLessThan(0);
    expect(joined.delay).toBeGreaterThanOrEqual(-110);
    expect(joined.easing).toBe(first.easing);
    expect(joined.duration).toBe(first.duration);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});

test("O13: with no live line mounted (reader scrolled away) a turn end is not captured and nothing plays", () => {
  const p = page();
  p.draw("worked-old", "worked", 0, 34);
  p.draw("answer", "assistant", 34, 50);
  expect(captureTurnEnd(p.thread, p.thread, [row("worked-u", "worked"), row("answer")], "chat")).toBeUndefined();
  expect(p.played.length).toBe(0);
  p.dom.window.close();
});

test("O14: a held Worked closing on return is captured without a live line and plays the fold", () => {
  const p = page();
  // The reader is back at the latest row: the held turn's work is still open over its Worked line.
  p.draw("worked-u", "worked", 0, 34);
  p.draw("work", "activity", 34, 60);
  p.draw("answer", "assistant", 94, 50);
  const after = [row("worked-u", "worked"), row("answer")];
  expect(captureTurnEnd(p.thread, p.thread, after, "chat")).toBeUndefined();
  const capture = captureTurnEnd(p.thread, p.thread, after, "chat", true)!;
  expect(capture).toBeDefined();
  expect(capture.rows.some((entry) => entry.copy)).toBe(true);
  p.thread.replaceChildren();
  p.draw("worked-u", "worked", 0, 34);
  p.draw("answer", "assistant", 34, 50);
  const fold = playTurnEnd(p.thread, capture, "chat")!;
  try {
    expect(fold).toBeDefined();
    // The replay Leo reads on scroll back: the copy of the work fades and the reply rises.
    expect(p.played.some((e) => e.keyframes.at(-1)?.opacity === 0)).toBe(true);
    expect(translates(p.played).length).toBeGreaterThan(0);
  } finally {
    settleTurnEnd(p.thread, fold);
    p.dom.window.close();
  }
});
