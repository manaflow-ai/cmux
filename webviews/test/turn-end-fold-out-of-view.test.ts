// A turn-end fold plays only where the reader can see it, and his own scroll settles one in flight
// (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1 "inside the view only" and rule 4
// "a reader's scroll finishes motion in flight"; hq#18682).
//
// Leo, 2026-11-22: "your chat folds or whatever, i scroll down, some bullshit ABOVE folds...? and
// plays an animation!? so there's some bullshit animation where i dont expect it to be, which is
// horrendous."
//
// Mounted is not seen: the transcript's overscan holds viewports of rows above and below the view, so
// a turn whose running line and folded work are all up there swaps its rows with no motion
// (`captureTurnEnd` captures it `silent` and nothing plays, while the turn's end still settles the
// fold before it, the follow motion and the tail glide's clip). And once a fold does play, an input
// the reader scrolls with -- a wheel, a touch drag, a press, PageDown -- arms it, and the view's own
// scroll from it ends the fold where its rows land, instead of the fold's passes turning the
// reader's scroll into motion. An input the view does not answer (a wheel over a code block's own
// scroller, one at a bottom that cannot move) is not his scroll and leaves the fold playing.
//
// jsdom has no layout: each row's box is its inline `top` and `height`, and the scroller's is the
// view, as fold-exit-before-move.test.ts lays its rows out. Every animation is recorded, never timed.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  TURN_END_ATTR,
  captureTurnEnd,
  playTurnEnd,
  settleTurnEnd,
  type TurnEndCapture,
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
  // jsdom never scrolls, so the view's offset is the test's to move: what the fold reads to tell a
  // reader's scroll from an input the view did not answer.
  let offset = 0;
  Object.defineProperty(scroller, "scrollTop", {
    configurable: true,
    get: () => offset,
    set: (value: number) => {
      offset = value;
    },
  });
  /// The view's own `scroll`, at `to` (the same offset: an input a bottom that cannot move, or a code
  /// block's own scroller, swallowed).
  const scrolls = (to = offset) => {
    offset = to;
    scroller.dispatchEvent(new window.Event("scroll"));
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
  /// The rows a running turn draws, from `top`: its open header, the work under it, the answer
  /// streaming in and the running line last.
  const running = (top: number) => {
    draw("working-u", "working", top, 34);
    draw("work", "activity", top + 34, 60);
    draw("answer", "assistant", top + 94, 50);
    draw(LIVE_THINKING, "thinking", top + 144, 22);
  };
  /// What the swap places: the closed line and the answer under it.
  const swapped = () => {
    thread.replaceChildren();
    draw("worked-u", "worked", 100, 34);
    draw("answer", "assistant", 134, 50);
  };
  return {
    dom,
    window,
    scroller,
    thread,
    draw,
    running,
    swapped,
    played,
    scrolls,
  };
}

test("a turn ending in the view folds: the work it takes away leaves a copy", () => {
  const sheet = page({ top: 0, height: 300 });
  try {
    sheet.running(0);
    const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
    expect(capture).toBeDefined();
    expect(capture!.rows.some((entry) => entry.id === "work" && entry.copy !== undefined)).toBe(true);
  } finally {
    sheet.dom.window.close();
  }
});

test("a turn ending below or above the view is captured silent: the swap applies at once", () => {
  for (const [name, view, top] of [
    ["below", { top: 0, height: 300 }, 1000],
    ["above", { top: 600, height: 300 }, 0],
  ] as const) {
    const sheet = page(view);
    try {
      sheet.running(top);
      // Mounted in the overscan is not seen (Leo's "some bullshit ABOVE folds ... and plays an animation").
      // The capture is taken all the same: its caller settles the fold before it, the follow motion and
      // the tail glide's held clip on it, and a missing capture left that clip hiding the reply's lines.
      const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
      expect(capture?.silent, name).toBe(true);
      expect(capture!.rows, name).toEqual([]);
      sheet.swapped();
      expect(playTurnEnd(sheet.thread, capture!, "chat", sheet.scroller), name).toBeUndefined();
      expect(sheet.thread.hasAttribute(TURN_END_ATTR), name).toBe(false);
      expect(sheet.played, name).toEqual([]);
    } finally {
      sheet.dom.window.close();
    }
  }
});

test("the work in view folds though the running line sits below the view", () => {
  const sheet = page({ top: 0, height: 300 });
  try {
    // The header and the work are in the view; the answer's tail and the running line are under it.
    sheet.running(200);
    expect(captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat")?.silent).toBeUndefined();
  } finally {
    sheet.dom.window.close();
  }
});

test("an empty running line at the view's bottom edge is where the reader is looking", () => {
  const sheet = page({ top: 0, height: 300 });
  try {
    // A turn of words alone keeps its running line's row at no height, right at the edge.
    sheet.draw(LIVE_THINKING, "thinking", 300, 0);
    sheet.draw("work", "activity", 310, 60);
    expect(captureTurnEnd(sheet.thread, sheet.scroller, [row("worked-u", "worked")], "chat")?.silent).toBeUndefined();
  } finally {
    sheet.dom.window.close();
  }
});

test("a held Worked for closes with no motion out of the view, and folds in it", () => {
  for (const [name, view, held, want] of [
    ["out of view", { top: 900, height: 300 }, true, "silent"],
    ["in view", { top: 0, height: 300 }, true, "folds"],
    // With no running line and nothing held, there is no turn end at all: nothing to settle either.
    ["no live line", { top: 0, height: 300 }, false, "none"],
  ] as const) {
    const sheet = page(view);
    try {
      sheet.draw("working-u", "working", 0, 34);
      sheet.draw("work", "activity", 34, 60);
      sheet.draw("answer", "assistant", 94, 50);
      const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat", held);
      const got = capture === undefined ? "none" : capture.silent ? "silent" : "folds";
      expect(got, name).toBe(want);
    } finally {
      sheet.dom.window.close();
    }
  }
});

/// A fold in flight over a scroller the reader can act on.
function folding() {
  const sheet = page({ top: 0, height: 300 });
  sheet.running(0);
  const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat") as TurnEndCapture;
  expect(capture).toBeDefined();
  const copies = capture.rows.flatMap((entry) => (entry.copy ? [entry.copy] : []));
  expect(copies.length).toBeGreaterThan(0);
  sheet.swapped();
  const fold = playTurnEnd(sheet.thread, capture, "chat", sheet.scroller)!;
  expect(fold).toBeDefined();
  expect(sheet.thread.hasAttribute(TURN_END_ATTR)).toBe(true);
  expect(fold.copies.size).toBe(copies.length);
  const send = (name: string, target: HTMLElement) =>
    target.dispatchEvent(new sheet.window.Event(name, { bubbles: true }));
  const key = (which: string, target: HTMLElement) =>
    target.dispatchEvent(new sheet.window.KeyboardEvent("keydown", { key: which, bubbles: true }));
  /// Whether the fold is still playing: its attribute, its copies in the thread, and its animations.
  const playing = () => ({
    marked: sheet.thread.hasAttribute(TURN_END_ATTR),
    copies: fold.copies.size,
    drawn: copies.filter((copy) => copy.isConnected).length,
    unfinished: sheet.played.filter((entry) => entry.finished === 0).length,
  });
  return { ...sheet, fold, copies, send, key, playing };
}

test("a wheel the view answers settles the fold: its rows land and its copies go", () => {
  const sheet = folding();
  try {
    expect(sheet.playing().unfinished).toBeGreaterThan(0);
    sheet.send("wheel", sheet.scroller);
    // The input alone is not the scroll: the view's own `scroll`, at a new offset, is.
    expect(sheet.playing().marked).toBe(true);
    sheet.scrolls(120);
    expect(sheet.playing()).toEqual({
      marked: false,
      copies: 0,
      drawn: 0,
      unfinished: 0,
    });
  } finally {
    settleTurnEnd(sheet.thread, sheet.fold);
    sheet.dom.window.close();
  }
});

test("an input the view does not answer leaves the fold playing", () => {
  // A wheel over a code block's own scroller, or at a bottom that cannot move: the input bubbles
  // here and the view stays where it was, so the reader never scrolled.
  const sheet = folding();
  try {
    sheet.send("wheel", sheet.thread.querySelector<HTMLElement>(".acpmux-row")!);
    sheet.scrolls();
    expect(sheet.playing().marked).toBe(true);
    expect(sheet.playing().copies).toBe(sheet.copies.length);
  } finally {
    settleTurnEnd(sheet.thread, sheet.fold);
    sheet.dom.window.close();
  }
});

test("a touch drag the view answers settles the fold", () => {
  const sheet = folding();
  try {
    sheet.send("touchmove", sheet.thread.querySelector<HTMLElement>(".acpmux-row")!);
    sheet.scrolls(40);
    expect(sheet.playing()).toEqual({
      marked: false,
      copies: 0,
      drawn: 0,
      unfinished: 0,
    });
  } finally {
    settleTurnEnd(sheet.thread, sheet.fold);
    sheet.dom.window.close();
  }
});

test("a press anywhere in the view arms it: the drag that follows settles the fold", () => {
  // The space under a chat shorter than the view targets the scroller, and a press on a row can be
  // the start of a scrollbar drag or a selection: either way only a moved view ends the fold.
  for (const where of ["scroller", "row"] as const) {
    const sheet = folding();
    try {
      sheet.send(
        "pointerdown",
        where === "scroller" ? sheet.scroller : sheet.thread.querySelector<HTMLElement>(".acpmux-row")!,
      );
      expect(sheet.playing().marked, where).toBe(true);
      sheet.scrolls(80);
      expect(sheet.playing(), where).toEqual({
        marked: false,
        copies: 0,
        drawn: 0,
        unfinished: 0,
      });
    } finally {
      settleTurnEnd(sheet.thread, sheet.fold);
      sheet.dom.window.close();
    }
  }
});

test("a reader who scrolls by keyboard ends the fold; another key does not", () => {
  for (const [key, want] of [
    ["PageDown", false],
    ["ArrowUp", false],
    [" ", false],
    ["Home", false],
    ["k", true],
  ] as const) {
    const sheet = folding();
    try {
      sheet.key(key, sheet.thread.querySelector<HTMLElement>(".acpmux-row")!);
      sheet.scrolls(60);
      expect(sheet.playing().marked, key).toBe(want);
    } finally {
      settleTurnEnd(sheet.thread, sheet.fold);
      sheet.dom.window.close();
    }
  }
});

test("the view's own scroll with no input before it keeps the fold: the pinned bottom following", () => {
  const sheet = folding();
  try {
    sheet.scrolls(200);
    expect(sheet.playing().marked).toBe(true);
    expect(sheet.playing().copies).toBe(sheet.copies.length);
  } finally {
    settleTurnEnd(sheet.thread, sheet.fold);
    sheet.dom.window.close();
  }
});

test("a view with no height yet has not been laid out: the fold is captured, not swallowed", () => {
  // A pane whose transcript mounts before its first layout reads as a sliver at the top, which would
  // leave every row "out of view" and swallow a fold the reader is about to see.
  const sheet = page({ top: 0, height: 0 });
  try {
    sheet.running(0);
    const capture = captureTurnEnd(sheet.thread, sheet.scroller, ENDED, "chat");
    expect(capture?.silent).toBeUndefined();
    expect(capture!.rows.some((entry) => entry.id === "work" && entry.copy !== undefined)).toBe(true);
  } finally {
    sheet.dom.window.close();
  }
});
