// Nothing animates out of the view (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1:
// "inside the view only"; hq#18682). Leo, 2026-11-22: "your chat folds or whatever, i scroll down,
// some bullshit ABOVE folds...? and plays an animation!? so there's some bullshit animation where i
// dont expect it to be, which is horrendous."
//
// The transcript's overscan mounts up to four viewports of rows the reader cannot see, and each row's
// CSS motion (its entrance, the streamed words' fade, the Thinking and Worked-for rolls) played
// there, half done by the time he scrolled to it. offscreenMotion.ts watches the scroller: a row the
// commit added or re-classed out of the view has its paint-only motions finished in the microtask
// after the commit, before the frame that would draw them, so the row is drawn once, at its end.
//
// jsdom has no animations, so the engine's side is stubbed: `getAnimations` per element, and the
// CSSAnimation and CSSTransition classes the gate tells a row's own CSS motion by. The boxes come
// from each element's inline `top`, `height` and `width`, which is what a view and a row's place are
// here. What is asserted is which motions were finished, never any timing.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { endOffscreenMotion, outOfView } from "../src/agent-session/acpmux/conversation/offscreenMotion";

/// A stand-in for one of the engine's animations: everything offscreenMotion.ts reads of it, and a
/// count of the times it was finished.
class Motion {
  playState = "running";
  finished = 0;
  readonly effect: {
    getKeyframes(): Keyframe[];
    getComputedTiming(): { endTime: number };
  };
  /// Set on a transition only, as the engine sets it (CSSTransition.transitionProperty).
  transitionProperty?: string;
  constructor(keyframes: Keyframe[], endTime: number, property?: string) {
    this.effect = {
      getKeyframes: () => keyframes,
      getComputedTiming: () => ({ endTime }),
    };
    if (property !== undefined) this.transitionProperty = property;
  }
  finish(): void {
    this.finished += 1;
    this.playState = "finished";
  }
}

/// A transcript scroller whose boxes are its elements' inline `top`, `height` and `width`.
function page(view: { top: number; height: number }) {
  const dom = new JSDOM('<!doctype html><div class="acpmux-scroll"></div>', {
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const px = (value: string, fallback: number) => (value === "" ? fallback : Number.parseFloat(value));
  const proto = window.HTMLElement.prototype;
  Object.defineProperty(proto, "offsetTop", {
    configurable: true,
    get(this: HTMLElement) {
      return px(this.style.top, 0);
    },
  });
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return px(this.style.height, 0);
    },
  });
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const top = px(this.style.top, 0);
    const height = px(this.style.height, 0);
    const width = px(this.style.width, 100);
    return {
      top,
      bottom: top + height,
      height,
      width,
      left: 0,
      right: width,
      x: 0,
      y: top,
      toJSON() {},
    };
  };
  // The classes the gate tells a row's own CSS motion by: a WAAPI animation (a fold's clip, a glide)
  // is neither, and is its owner's to gate (turnEndFold.ts).
  class CssAnimation extends Motion {}
  class CssTransition extends Motion {}
  const scope = window as unknown as Record<string, unknown>;
  scope.CSSAnimation = CssAnimation;
  scope.CSSTransition = CssTransition;
  const playing = new WeakMap<Element, Motion[]>();
  window.Element.prototype.getAnimations = function (this: Element, options?: { subtree?: boolean }) {
    const found = [...(playing.get(this) ?? [])];
    if (options?.subtree) for (const node of this.querySelectorAll("*")) found.push(...(playing.get(node) ?? []));
    return found as unknown as Animation[];
  };
  // offscreenMotion.ts reads its nodes with `instanceof Element`, the page's own class.
  const globals = globalThis as { Element?: unknown };
  const hadElement = "Element" in globals;
  const priorElement = globals.Element;
  globals.Element = window.Element;

  const scroller = window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  scroller.style.top = `${view.top}px`;
  scroller.style.height = `${view.height}px`;

  /// An element with a box, appended to `parent`. `width: 0` with `height: 0` is a line that has
  /// mounted with no box yet.
  const add = (parent: HTMLElement, className: string, box: { top: number; height: number; width?: number }) => {
    const node = window.document.createElement("div");
    node.className = className;
    node.style.top = `${box.top}px`;
    node.style.height = `${box.height}px`;
    if (box.width !== undefined) node.style.width = `${box.width}px`;
    parent.append(node);
    return node;
  };
  const plays = <T extends Motion>(node: Element, motion: T): T => {
    playing.set(node, [...(playing.get(node) ?? []), motion]);
    return motion;
  };
  /// A row's entrance or a word's fade: a finite CSS animation that only paints.
  const fade = () => new CssAnimation([{ opacity: 0 }, { opacity: 1 }], 200);
  /// A clock's roll: a finite CSS transition that only paints.
  const roll = () => new CssTransition([], 200, "color");
  /// A motion that sizes or places the box, which ending at once would step the rows in view.
  const grow = () => new CssTransition([], 200, "height");
  /// A spinner: an ambient loop, no end to draw.
  const loop = () => new CssAnimation([{ opacity: 0 }, { opacity: 1 }], Infinity);
  /// A WAAPI motion, which is not one of the engine's CSS animation classes.
  const waapi = () => new Motion([{ translate: "0 10px" }], 200);
  /// The mutation observer delivers in the microtask after the commit: one turn of the event loop
  /// runs it, with nothing timed.
  const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  const close = () => {
    if (hadElement) globals.Element = priorElement;
    else delete globals.Element;
    window.close();
  };
  return {
    window,
    scroller,
    add,
    plays,
    fade,
    roll,
    grow,
    loop,
    waapi,
    flush,
    close,
  };
}

test("a row that mounts out of the view is drawn at its end, one that mounts in it plays", async () => {
  const sheet = page({ top: 0, height: 300 });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const below = sheet.plays(sheet.add(sheet.scroller, "acpmux-row", { top: 400, height: 60 }), sheet.fade());
    const above = sheet.plays(sheet.add(sheet.scroller, "acpmux-row", { top: -200, height: 60 }), sheet.fade());
    const seen = sheet.plays(sheet.add(sheet.scroller, "acpmux-row", { top: 100, height: 60 }), sheet.fade());
    await sheet.flush();
    expect([below.finished, above.finished]).toEqual([1, 1]);
    expect(seen.finished).toBe(0);
  } finally {
    stop();
    sheet.close();
  }
});

test("a row re-classed out of the view has its roll drawn at its end", async () => {
  const sheet = page({ top: 0, height: 300 });
  const row = sheet.add(sheet.scroller, "acpmux-row", { top: 500, height: 40 });
  const line = sheet.add(row, "acpmux-row__line", { top: 500, height: 20 });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const rolling = sheet.plays(line, sheet.roll());
    // A class change on the row, with the motion inside it: the row's box is what is out of view.
    row.classList.add("acpmux-row--working");
    await sheet.flush();
    expect(rolling.finished).toBe(1);
  } finally {
    stop();
    sheet.close();
  }
});

test("a motion that sizes the box out of the view is left alone; a paint-only one on the same row is not", async () => {
  const sheet = page({ top: 0, height: 300 });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const row = sheet.add(sheet.scroller, "acpmux-row", {
      top: 500,
      height: 40,
    });
    const sizing = sheet.plays(row, sheet.grow());
    const painting = sheet.plays(row, sheet.roll());
    const ambient = sheet.plays(row, sheet.loop());
    const owned = sheet.plays(row, sheet.waapi());
    await sheet.flush();
    expect(painting.finished).toBe(1);
    // A height out of view still moves the rows in view when the bottom is pinned (the anchor pass
    // and fold.ts own it), an infinite loop has no end to draw, and a WAAPI motion gates itself.
    expect([sizing.finished, ambient.finished, owned.finished]).toEqual([0, 0, 0]);
  } finally {
    stop();
    sheet.close();
  }
});

test("a long row in the view has the words below the view's edge drawn at their end", async () => {
  const sheet = page({ top: 0, height: 300 });
  const row = sheet.add(sheet.scroller, "acpmux-row", {
    top: 200,
    height: 300,
  });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const rowMotion = sheet.plays(row, sheet.fade());
    const words = sheet.plays(sheet.add(row, "acpmux-word", { top: 320, height: 20 }), sheet.fade());
    // A line that has mounted with no box yet reads as in view (it is about to be laid out there).
    const unlaid = sheet.plays(sheet.add(row, "acpmux-line", { top: 0, height: 0, width: 0 }), sheet.fade());
    await sheet.flush();
    expect(words.finished).toBe(1);
    expect([rowMotion.finished, unlaid.finished]).toEqual([0, 0]);
  } finally {
    stop();
    sheet.close();
  }
});

test("a motion no mutation started out of the view is drawn at its end when it starts", async () => {
  const sheet = page({ top: 0, height: 300 });
  const below = sheet.add(sheet.scroller, "acpmux-row", {
    top: 500,
    height: 40,
  });
  const seen = sheet.add(sheet.scroller, "acpmux-row", { top: 10, height: 40 });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    // No commit added or re-classed these rows: `animationstart` and `transitionrun` are what catch a
    // transition from an inherited value.
    const started = sheet.plays(below, sheet.fade());
    const ran = sheet.plays(below, sheet.roll());
    const playing = sheet.plays(seen, sheet.fade());
    below.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    below.dispatchEvent(new sheet.window.Event("transitionrun", { bubbles: true }));
    seen.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    expect(started.finished).toBeGreaterThanOrEqual(1);
    expect(ran.finished).toBeGreaterThanOrEqual(1);
    expect(playing.finished).toBe(0);
  } finally {
    stop();
    sheet.close();
  }
});

test("an element out of the view that is no part of a row is left alone", async () => {
  const sheet = page({ top: 0, height: 300 });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const spacer = sheet.add(sheet.scroller, "acpmux-spacer", {
      top: 900,
      height: 40,
    });
    const motion = sheet.plays(spacer, sheet.fade());
    // Neither pass claims it: the virtualizer's spacers, the header and the composer are not rows,
    // and only a row's own motion is this gate's to draw.
    await sheet.flush();
    spacer.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    spacer.dispatchEvent(new sheet.window.Event("transitionrun", { bubbles: true }));
    expect(motion.finished).toBe(0);
  } finally {
    stop();
    sheet.close();
  }
});

test("a line with no box yet inside a row out of the view is drawn at its end when it starts", async () => {
  const sheet = page({ top: 0, height: 300 });
  const row = sheet.add(sheet.scroller, "acpmux-row", { top: 800, height: 40 });
  // A line that has just mounted has no box of its own, so its own box reads as in the view, and the
  // row it sits in is what the reader cannot see. The event pass is the only one that sees the
  // motions a `data-*` flip starts, so judging the target alone left them playing out there.
  const unlaid = sheet.add(row, "acpmux-row__line", {
    top: 0,
    height: 0,
    width: 0,
  });
  const near = sheet.add(sheet.scroller, "acpmux-row", {
    top: 100,
    height: 40,
  });
  const laid = sheet.add(near, "acpmux-row__line", {
    top: 0,
    height: 0,
    width: 0,
  });
  const stop = endOffscreenMotion(sheet.scroller);
  try {
    const out = sheet.plays(unlaid, sheet.fade());
    const seen = sheet.plays(laid, sheet.fade());
    unlaid.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    laid.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    expect(out.finished).toBeGreaterThanOrEqual(1);
    expect(seen.finished).toBe(0);
  } finally {
    stop();
    sheet.close();
  }
});

test("the unsubscribe gives the view back: nothing out of it is touched again", async () => {
  const sheet = page({ top: 0, height: 300 });
  const stop = endOffscreenMotion(sheet.scroller);
  stop();
  try {
    const row = sheet.add(sheet.scroller, "acpmux-row", {
      top: 500,
      height: 40,
    });
    const motion = sheet.plays(row, sheet.fade());
    row.dispatchEvent(new sheet.window.Event("animationstart", { bubbles: true }));
    await sheet.flush();
    expect(motion.finished).toBe(0);
  } finally {
    sheet.close();
  }
});

test("no scroller: the gate installs nothing and unsubscribes", () => {
  expect(typeof endOffscreenMotion(null)).toBe("function");
  expect(() => endOffscreenMotion(undefined)()).not.toThrow();
});

test("a box misses the view when it is wholly past an edge, and its edges count as in it", () => {
  const sheet = page({ top: 100, height: 200 });
  try {
    const row = (top: number, height: number, width?: number) =>
      sheet.add(sheet.scroller, "acpmux-row", { top, height, width });
    expect(outOfView(row(0, 50), sheet.scroller)).toBe(true);
    expect(outOfView(row(400, 50), sheet.scroller)).toBe(true);
    expect(outOfView(row(150, 50), sheet.scroller)).toBe(false);
    // Overlapping an edge is in the view; a 1 px lap over it is rounding, and misses.
    expect(outOfView(row(80, 40), sheet.scroller)).toBe(false);
    expect(outOfView(row(60, 41), sheet.scroller)).toBe(true);
    expect(outOfView(row(290, 40), sheet.scroller)).toBe(false);
    expect(outOfView(row(299, 40), sheet.scroller)).toBe(true);
    // A box that has none yet is about to be laid out in the view.
    expect(outOfView(row(900, 0, 0), sheet.scroller)).toBe(false);
  } finally {
    sheet.close();
  }
});
