// A turn-end fold plays only on the rows the reader can see, row by row -- not just folds, rows
// (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1 "inside the view only":
// "An animation plays only for a change the reader caused or is looking at, and only where the reader
// can see it").
//
// Leo, 2026-11-22: "your chat folds or whatever, i scroll down, some bullshit ABOVE folds...? and
// plays an animation!? so there's some bullshit animation where i dont expect it to be, which is
// horrendous ... edge cases at teh top area of teh screeen".
//
// `captureTurnEnd` already drops a fold no part of which is seen (`silent`,
// turn-end-fold-out-of-view.test.ts). That is per fold: once any part of a turn's end is in the view
// the fold plays, and before this guard it played on EVERY row it changed, including the work and the
// header far above the view in the transcript's overscan. The fold fuzzer
// (webviews/scripts/fold-fuzz.ts, 500 seeds, `--look fade`) measured 19951 of those starts, 483 of
// 500 seeds with at least one, the detector's `offscreen-start`.
//
// So the guard is per row: a row whose move begins and ends wholly outside the view takes its swap at
// once -- drawn at its place, full ink, no `element.animate` call -- and a copy of a row the turn took
// away, out there, goes to no ink without an exit fade. The rows in the view animate exactly as
// before. A row is never latched out: `pass()` runs again on every scroll and placement, so a row the
// reader scrolls to mid-fold animates what is left of its path. A copy IS latched: its final state is
// gone, and a reader who scrolls to its place must find the swap there, not a row the turn removed
// fading in from full ink.
//
// jsdom has no layout: each row's box is its inline `top` and `height`, and the scroller's is the
// view, as turn-end-fold-out-of-view.test.ts and fold-exit-before-move.test.ts lay their rows out.
// Every animation is recorded against the element it was called on, never timed.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  TURN_END_ATTR,
  captureTurnEnd,
  playTurnEnd,
  settleTurnEnd,
} from "../src/agent-session/acpmux/conversation/turnEndFold";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind,
});

/// What the swap after the turn's end draws: the closed Worked for and the answer.
const ENDED = [row("worked-u", "worked"), row("answer")];

/// A transcript inside a scroller, both laid out by their inline `top` and `height`.
function page(view: { top: number; height: number }) {
  const dom = new JSDOM('<!doctype html><div class="acpmux-scroll"><main class="acpmux-thread"></main></div>', {
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const proto = window.HTMLElement.prototype;
  Object.defineProperty(proto, "offsetTop", {
    configurable: true,
    get(this: HTMLElement) {
      return Number.parseFloat(this.style.top) || 0;
    },
  });
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return Number.parseFloat(this.style.height) || 0;
    },
  });
  proto.getBoundingClientRect = function (this: HTMLElement) {
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
  const played: { node: HTMLElement; finished: number; cancelled: number }[] = [];
  proto.animate = function (this: HTMLElement) {
    const entry = { node: this, finished: 0, cancelled: 0 };
    played.push(entry);
    return {
      finish() {
        entry.finished += 1;
      },
      cancel() {
        entry.cancelled += 1;
      },
      onfinish: null,
      oncancel: null,
    } as unknown as Animation;
  };
  const scroller = window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  scroller.style.top = `${view.top}px`;
  scroller.style.height = `${view.height}px`;
  let offset = 0;
  Object.defineProperty(scroller, "scrollTop", {
    configurable: true,
    get: () => offset,
    set: (value: number) => {
      offset = value;
    },
  });
  /// The view's own `scroll` with no input before it: the fold keeps playing and reads every place
  /// again (turn-end-fold-out-of-view.test.ts, "the pinned bottom following").
  const scrolls = () => scroller.dispatchEvent(new window.Event("scroll"));
  /// Where the reader is looking now: in jsdom the view is the scroller's own box, so moving it is
  /// how this test scrolls the transcript under him.
  const looksAt = (top: number) => {
    scroller.style.top = `${top}px`;
  };
  const thread = window.document.querySelector<HTMLElement>(".acpmux-thread")!;
  const draw = (id: string, kind: string, top: number, height: number) => {
    const node = window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind}`;
    node.dataset.rowId = id;
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    node.textContent = `${kind} ${id}`;
    thread.append(node);
    return node;
  };
  /// Whether an element's drawn band meets the view, edge included (`captureTurnEnd`'s own `seen`).
  const seen = (node: HTMLElement) => {
    const box = node.getBoundingClientRect();
    const top = Number.parseFloat(scroller.style.top);
    const bottom = top + Number.parseFloat(scroller.style.height);
    return box.bottom >= top && box.top <= bottom;
  };
  return { dom, window, scroller, thread, draw, played, scrolls, looksAt, seen };
}

/// A turn that ends with its header and its work far above the view, and its answer and running line
/// in it: the fold plays (part of the turn's end is seen), and the rows up there are the ones no
/// animation may start on. The gap between them is the transcript's overscan, which holds viewports of
/// rows above the view.
function endsAboveTheView() {
  const sheet = page({ top: 300, height: 300 });
  // Above the view: the open header and the turn's work. The work goes, so it leaves a copy up there.
  const header = sheet.draw("working-u", "working", 0, 34);
  const work = sheet.draw("work", "activity", 34, 60);
  // In the view: the answer, and the running line the swap takes away.
  sheet.draw("answer", "assistant", 400, 50);
  sheet.draw(LIVE_THINKING, "thinking", 450, 22);
  const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
  expect(capture).toBeDefined();
  // The running line in the view is what makes this fold play at all.
  expect(capture!.silent).toBeUndefined();
  const copyOf = (id: string) => capture!.rows.find((entry) => entry.id === id)?.copy;
  const copies = { header: copyOf("working-u")!, work: copyOf("work")!, line: copyOf(LIVE_THINKING)! };
  for (const [name, copy] of Object.entries(copies)) expect(copy, name).toBeDefined();
  // The swap: the closed Worked for where the open header was, the answer 10 px down from its place.
  sheet.thread.replaceChildren();
  const worked = sheet.draw("worked-u", "worked", 0, 34);
  const answer = sheet.draw("answer", "assistant", 410, 50);
  return { ...sheet, capture: capture!, header, work, copies, worked, answer };
}

test("a fold whose rows are above the view starts no animation on them, and still plays in the view", () => {
  const sheet = endsAboveTheView();
  const fold = playTurnEnd(sheet.thread, sheet.capture, "chat", sheet.scroller);
  try {
    // The fold plays: the answer and the running line's copy are in the view.
    expect(fold).toBeDefined();
    expect(sheet.thread.hasAttribute(TURN_END_ATTR)).toBe(true);
    const animated = new Set(sheet.played.map((entry) => entry.node));
    // The rule, as the detector states it: no start on a row outside the view.
    expect([...animated].filter((node) => !sheet.seen(node)).map((node) => node.textContent)).toEqual([]);
    // Each row up there by name: the closed Worked for the swap added, the old header's copy, and the
    // copy of the work the turn folded away. Before the guard all three animated.
    expect(animated.has(sheet.worked), "the closed Worked for above the view").toBe(false);
    expect(animated.has(sheet.copies.header), "the open header's copy above the view").toBe(false);
    expect(animated.has(sheet.copies.work), "the folded work's copy above the view").toBe(false);
    // A copy that plays no exit fade is drawn at its final state instead: no ink, not full ink held
    // for the fold's length. The row it pictured is gone from the new frame, and neither place is in
    // the view, so nothing the reader sees is drawn in two places or in neither.
    expect(sheet.copies.header.style.opacity, "the header's copy").toBe("0");
    expect(sheet.copies.work.style.opacity, "the work's copy").toBe("0");
    // And the fold is not simply off: what the reader is looking at moves as it always did. The answer
    // slides its 10 px; the running line's copy fades out and travels.
    expect(animated.has(sheet.answer), "the answer in the view").toBe(true);
    expect(animated.has(sheet.copies.line), "the running line's copy in the view").toBe(true);
    expect(sheet.copies.line.style.opacity, "the running line's copy keeps its ink for its fade").toBe("");
  } finally {
    if (fold) settleTurnEnd(sheet.thread, fold);
    sheet.dom.window.close();
  }
});

test("a row the reader scrolls to mid-fold animates from that pass: it is never latched out", () => {
  const sheet = endsAboveTheView();
  const fold = playTurnEnd(sheet.thread, sheet.capture, "chat", sheet.scroller);
  try {
    expect(fold).toBeDefined();
    expect(new Set(sheet.played.map((entry) => entry.node)).has(sheet.worked)).toBe(false);
    // The reader scrolls up: the closed Worked for is in the view now. The fold reads every place
    // again on the view's scroll and plays it from here, in step with its own clock.
    sheet.looksAt(0);
    expect(sheet.seen(sheet.worked)).toBe(true);
    sheet.scrolls();
    expect(new Set(sheet.played.map((entry) => entry.node)).has(sheet.worked)).toBe(true);
    // Its copies are another matter: their final state (gone) was applied while they were out of
    // sight, so they stay gone. Scrolled to, the reader finds the swap, not a removed row fading in.
    expect(new Set(sheet.played.map((entry) => entry.node)).has(sheet.copies.work)).toBe(false);
    expect(sheet.copies.work.style.opacity).toBe("0");
  } finally {
    if (fold) settleTurnEnd(sheet.thread, fold);
    sheet.dom.window.close();
  }
});

test("a view with no height yet has not been laid out: every row still folds", () => {
  // A pane whose transcript mounts before its first layout reads as a sliver at the top. Judging rows
  // against it would leave every one of them "out of view" and swallow the whole fold.
  const sheet = page({ top: 0, height: 0 });
  sheet.draw("working-u", "working", 0, 34);
  sheet.draw("work", "activity", 34, 60);
  sheet.draw("answer", "assistant", 94, 50);
  sheet.draw(LIVE_THINKING, "thinking", 144, 22);
  const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
  expect(capture?.silent).toBeUndefined();
  sheet.thread.replaceChildren();
  sheet.draw("worked-u", "worked", 0, 34);
  sheet.draw("answer", "assistant", 104, 50);
  const fold = playTurnEnd(sheet.thread, capture!, "chat", sheet.scroller);
  try {
    expect(fold).toBeDefined();
    expect(sheet.played.length).toBeGreaterThan(0);
  } finally {
    if (fold) settleTurnEnd(sheet.thread, fold);
    sheet.dom.window.close();
  }
});

// The case the fuzzer found, and the reason the guard needs two boxes rather than one. A row's
// captured `top` is in the view's coordinates of the moment it was captured, and `pass()` carries only
// the ANCHOR row across a reader's scroll (`scroller.scrollTop += moved`). So once the reader scrolls,
// every other row's remembered top is stale by the distance he moved: a row whose captured top is
// squarely in the view can be drawn far above it by the time the fold plays. Gated on the remembered
// top alone the fold animated exactly those rows -- the fault Leo reported, "i scroll down, some
// bullshit ABOVE folds...? and plays an animation!?". Measured on the fuzzer (look `fade`, 6 stray
// seeds): 89-102 starts allowed with the row's drawn box wholly outside the view, and 12
// `offscreen-start`; with the drawn box tested too, 0 and 1.
test("a row whose remembered top is stale after a scroll is judged by where it is drawn, not where it was", () => {
  // The turn ends with every row in the view, so nothing is gated out at capture time.
  const sheet = page({ top: 0, height: 300 });
  sheet.draw("working-u", "working", 10, 34);
  sheet.draw("work", "activity", 44, 60);
  sheet.draw("answer", "assistant", 104, 50);
  sheet.draw(LIVE_THINKING, "thinking", 154, 22);
  const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
  expect(capture).toBeDefined();
  expect(capture!.silent).toBeUndefined();
  // Each row was captured inside the view: the remembered tops alone say every row is seen.
  for (const entry of capture!.rows) expect(entry.top).toBeLessThan(300);
  const copyOf = (id: string) => capture!.rows.find((entry) => entry.id === id)?.copy;
  const headerCopy = copyOf("working-u")!;
  const workCopy = copyOf("work")!;
  // Now the reader scrolls far down before the fold plays: the rows are drawn high above the view,
  // while their captured tops still read as in it. Only the drawn box tells the truth.
  sheet.thread.replaceChildren();
  const worked = sheet.draw("worked-u", "worked", -620, 34);
  const answer = sheet.draw("answer", "assistant", -586, 50);
  sheet.looksAt(0);
  for (const node of [headerCopy, workCopy]) {
    node.style.top = `${Number.parseFloat(node.style.top) - 630}px`;
    sheet.thread.append(node);
  }
  const fold = playTurnEnd(sheet.thread, capture!, "chat", sheet.scroller);
  try {
    const animated = new Set(sheet.played.map((entry) => entry.node));
    // The rule, by the box each row is drawn in: nothing up there animates.
    expect([...animated].filter((node) => !sheet.seen(node)).map((node) => node.textContent)).toEqual([]);
    expect(animated.has(worked), "the closed Worked for, drawn above the view").toBe(false);
    expect(animated.has(answer), "the answer, drawn above the view").toBe(false);
    expect(animated.has(headerCopy), "the header's copy, drawn above the view").toBe(false);
    expect(animated.has(workCopy), "the work's copy, drawn above the view").toBe(false);
  } finally {
    if (fold) settleTurnEnd(sheet.thread, fold);
    sheet.dom.window.close();
  }
});
