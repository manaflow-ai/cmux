import { afterEach, beforeEach, expect, test } from "bun:test";
import { POPUP_INPUT_MS, settlePopup } from "../src/ui/popupSettle";

// A fake window and element: settlePopup takes everything from element.ownerDocument.defaultView,
// so no DOM is needed. Frames and timers run only when the test says so.
type Listener = (event: { type: string; target: unknown }) => void;

class FakeElement {
  attributes = new Map<string, string>();
  properties = new Map<string, string>();
  dataset: Record<string, string> = {};
  box = { width: 200, height: 100 };
  scroller = false;
  children: FakeElement[] = [];
  ownerDocument: { defaultView: FakeView };
  classList = { contains: () => false };
  style = {
    setProperty: (name: string, value: string) => void this.properties.set(name, value),
    removeProperty: (name: string) => void this.properties.delete(name),
  };
  constructor(view: FakeView) {
    this.ownerDocument = { defaultView: view };
  }
  getBoundingClientRect() {
    return this.box;
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  removeAttribute(name: string) {
    this.attributes.delete(name);
  }
  querySelector() {
    return this.scroller ? {} : null;
  }
  contains(node: unknown) {
    return node === this || this.children.includes(node as FakeElement);
  }
}

class FakeView {
  now = 0;
  frames: (() => void)[] = [];
  listeners = new Map<string, Listener[]>();
  added = 0;
  removed = 0;
  performance = { now: () => this.now };
  ResizeObserver = class {
    constructor(public callback: () => void) {}
    observe() {}
    disconnect() {}
  };
  requestAnimationFrame(callback: () => void) {
    this.frames.push(callback);
    return this.frames.length;
  }
  cancelAnimationFrame() {
    this.frames = [];
  }
  getComputedStyle() {
    return { overflowY: "visible" };
  }
  addEventListener(type: string, listener: Listener) {
    this.added += 1;
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  removeEventListener(type: string, listener: Listener) {
    this.removed += 1;
    this.listeners.set(
      type,
      (this.listeners.get(type) ?? []).filter((entry) => entry !== listener),
    );
  }
  fire(type: string, target: unknown = null) {
    for (const listener of this.listeners.get(type) ?? []) listener({ type, target });
  }
  /** Runs animation frames until none are queued. */
  frame() {
    for (let guard = 0; guard < 10 && this.frames.length > 0; guard += 1) {
      const run = this.frames;
      this.frames = [];
      for (const callback of run) callback();
    }
  }
}

let view: FakeView;
let timers: { at: number; run: () => void }[];
// settlePopup keeps its open popups (and whether the window is listened to) for the whole module:
// every popup a test opens is stopped after it, or the next test's window never gets listeners.
let stops: (() => void)[] = [];
const realSetTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;
const realInstance = globalThis.Node;

beforeEach(() => {
  view = new FakeView();
  timers = [];
  // `target instanceof Node` in the listener: the fakes count as nodes.
  (globalThis as { Node: unknown }).Node = FakeElement;
  (globalThis as { setTimeout: unknown }).setTimeout = (run: () => void, wait = 0) => {
    const timer = { at: view.now + wait, run };
    timers.push(timer);
    return timer;
  };
  (globalThis as { clearTimeout: unknown }).clearTimeout = (timer: unknown) => {
    timers = timers.filter((entry) => entry !== timer);
  };
});
afterEach(() => {
  for (const stop of stops) stop();
  stops = [];
  globalThis.setTimeout = realSetTimeout;
  globalThis.clearTimeout = realClearTimeout;
  (globalThis as { Node: unknown }).Node = realInstance;
});

/** Moves the clock and runs the timers that came due, then the frames they queued. */
function advance(ms: number) {
  view.now += ms;
  const due = timers.filter((timer) => timer.at <= view.now);
  timers = timers.filter((timer) => timer.at > view.now);
  for (const timer of due) timer.run();
  view.frame();
}

function open(setup?: (element: FakeElement) => void) {
  const element = new FakeElement(view);
  setup?.(element);
  const stop = settlePopup(element as unknown as HTMLElement);
  stops.push(stop);
  return { element, stop };
}

const settledOf = (element: FakeElement) => element.attributes.get("data-popup-settled");

test("settles after two frames with the three lengths and the floor", () => {
  const { element } = open();
  expect(settledOf(element)).toBeUndefined();
  view.frames.shift()!();
  expect(settledOf(element)).toBeUndefined();
  view.frame();
  expect(settledOf(element)).toBe("floor");
  expect(element.properties.get("--popup-settled-width")).toBe("200px");
  expect(element.properties.get("--popup-settled-floor")).toBe("200px");
  expect(element.properties.get("--popup-settled-height")).toBe("100px");
  expect(element.attributes.has("data-popup-floor")).toBe(true);
});

test("a tall popup with a scroller holds its whole height", () => {
  const { element } = open((node) => {
    node.box = { width: 200, height: 160 };
    node.scroller = true;
  });
  view.frame();
  expect(settledOf(element)).toBe("box");
});

test("a short popup with a scroller, or a tall one without, holds only a floor", () => {
  const short = open((node) => {
    node.box = { width: 200, height: 159 };
    node.scroller = true;
  });
  const plain = open((node) => {
    node.box = { width: 200, height: 300 };
  });
  view.frame();
  expect(settledOf(short.element)).toBe("floor");
  expect(settledOf(plain.element)).toBe("floor");
});

test("a key frees the box and it settles again after POPUP_INPUT_MS", () => {
  const { element } = open();
  view.frame();
  view.fire("keydown");
  expect(settledOf(element)).toBeUndefined();
  expect(element.properties.has("--popup-settled-width")).toBe(false);
  // The floor stays while freed.
  expect(element.attributes.has("data-popup-floor")).toBe(true);
  view.frame();
  expect(settledOf(element)).toBeUndefined();
  element.box = { width: 240, height: 120 };
  advance(POPUP_INPUT_MS);
  expect(settledOf(element)).toBe("floor");
  expect(element.properties.get("--popup-settled-width")).toBe("240px");
});

test("a pointerdown inside holds it free until pointerup", () => {
  const { element } = open();
  view.frame();
  view.fire("pointerdown", element);
  expect(settledOf(element)).toBeUndefined();
  advance(POPUP_INPUT_MS * 5);
  expect(settledOf(element)).toBeUndefined();
  view.fire("pointerup");
  advance(POPUP_INPUT_MS);
  expect(settledOf(element)).toBe("floor");
});

test("a pointerdown outside does not free it", () => {
  const { element } = open();
  view.frame();
  view.fire("pointerdown", new FakeElement(view));
  expect(settledOf(element)).toBe("floor");
});

test("the floor never goes down across a free and a settle", () => {
  const { element } = open();
  view.frame();
  expect(element.properties.get("--popup-settled-floor")).toBe("200px");
  view.fire("keydown");
  element.box = { width: 120, height: 80 };
  advance(POPUP_INPUT_MS);
  expect(settledOf(element)).toBe("floor");
  expect(element.properties.get("--popup-settled-width")).toBe("120px");
  expect(element.properties.get("--popup-settled-floor")).toBe("200px");
  view.fire("keydown");
  element.box = { width: 300, height: 80 };
  advance(POPUP_INPUT_MS);
  expect(element.properties.get("--popup-settled-floor")).toBe("300px");
});

test("a window resize resets the floor", () => {
  const { element } = open();
  view.frame();
  element.box = { width: 120, height: 80 };
  view.fire("resize");
  expect(settledOf(element)).toBeUndefined();
  expect(element.attributes.has("data-popup-floor")).toBe(false);
  view.frame();
  expect(element.properties.get("--popup-settled-floor")).toBe("120px");
});

test("a results or own popup is never settled", () => {
  for (const rule of ["results", "own"]) {
    const { element } = open((node) => {
      node.dataset.popupSettle = rule;
    });
    view.frame();
    expect(settledOf(element)).toBeUndefined();
    expect(element.properties.size).toBe(0);
    expect(element.attributes.has("data-popup-floor")).toBe(false);
  }
});

test("a window with no frames (a test DOM) is left alone", () => {
  (view as { requestAnimationFrame?: unknown }).requestAnimationFrame = undefined;
  const { element, stop } = open();
  expect(view.added).toBe(0);
  expect(element.attributes.size).toBe(0);
  stop();
});

test("a popup that is not drawn is not settled", () => {
  const { element } = open((node) => {
    node.box = { width: 0, height: 0 };
  });
  view.frame();
  expect(settledOf(element)).toBeUndefined();
});

test("stopping removes every attribute, property and window listener", () => {
  const { element, stop } = open();
  view.frame();
  expect(settledOf(element)).toBe("floor");
  const added = view.added;
  expect(added).toBeGreaterThan(0);
  stop();
  expect(element.attributes.size).toBe(0);
  expect(element.properties.size).toBe(0);
  expect(view.removed).toBe(added);
  for (const listeners of view.listeners.values()) expect(listeners).toHaveLength(0);
  // Nothing settles after the stop.
  view.frame();
  expect(settledOf(element)).toBeUndefined();
});

test("listeners are added once for many popups and removed with the last", () => {
  const first = open();
  const second = open();
  const added = view.added;
  expect(view.removed).toBe(0);
  first.stop();
  expect(view.removed).toBe(0);
  second.stop();
  expect(view.removed).toBe(added);
});
