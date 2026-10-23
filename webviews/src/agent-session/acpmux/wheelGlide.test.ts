// Which wheel events are a mouse wheel's notch (wheelGlide.ts): the values each engine dispatches.
// And where a glide stops: a stand-in scroller and frame clock, so each stop is checked frame by
// frame (the browser tests cover the motion itself). And the wheel forwarded from outside the
// transcript (Jump to latest, a stack gutter, the minimap's card: wheelPassThrough.ts).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { installWheelGlide, isWheelNotch } from "./wheelGlide";
import { forwardWheel } from "./wheelPassThrough";

const pixels = (deltaY: number, wheelDeltaY?: number) => ({ deltaY, deltaMode: 0, wheelDeltaY });

describe("isWheelNotch", () => {
  test("a wheel's lines or pages are a notch", () => {
    expect(isWheelNotch({ deltaY: 3, deltaMode: 1 })).toBe(true);
    expect(isWheelNotch({ deltaY: -1, deltaMode: 2 })).toBe(true);
  });

  test("Chromium: a tick counts 120 in wheelDeltaY whatever its pixels", () => {
    // A slow notch on macOS, a fast one, and Windows' 100px.
    expect(isWheelNotch(pixels(4.000244140625, -120))).toBe(true);
    expect(isWheelNotch(pixels(-89.267578125, 240))).toBe(true);
    expect(isWheelNotch(pixels(100, -120))).toBe(true);
  });

  test("Chromium: a precise scroll's wheelDeltaY is three times its pixels", () => {
    expect(isWheelNotch(pixels(13, -39))).toBe(false);
    expect(isWheelNotch(pixels(2.5, -7))).toBe(false);
    // 40px is a precise 40px or a whole line: left to the engine.
    expect(isWheelNotch(pixels(40, -120))).toBe(false);
  });

  test("WebKit on macOS: a notch scrolls fixed-point lines times 40", () => {
    // 0.1 lines (a slow notch), an accelerated 0.535 lines, and about 2.5 lines down and up.
    expect(isWheelNotch(pixels(4.000244140625, -12))).toBe(true);
    expect(isWheelNotch(pixels(21.4019775390625, -64))).toBe(true);
    expect(isWheelNotch(pixels(100.006103515625, -300))).toBe(true);
    expect(isWheelNotch(pixels(-100.006103515625, 300))).toBe(true);
  });

  test("WebKit: a trackpad scrolls whole points", () => {
    expect(isWheelNotch(pixels(7, -21))).toBe(false);
    expect(isWheelNotch(pixels(-120, 360))).toBe(false);
    expect(isWheelNotch(pixels(2.5, -7))).toBe(false);
    expect(isWheelNotch(pixels(0.75, -2))).toBe(false);
    // 25/64px and 85/64px sit on the fixed-point grid too: a fraction of a point is a trackpad's.
    expect(isWheelNotch(pixels(0.390625, -1))).toBe(false);
    expect(isWheelNotch(pixels(-1.328125, 3))).toBe(false);
    // Any other fraction is not a fixed-point line either.
    expect(isWheelNotch(pixels(6.3636, -19))).toBe(false);
  });

  test("no movement, or no legacy delta, is not a notch", () => {
    expect(isWheelNotch(pixels(0, 0))).toBe(false);
    expect(isWheelNotch(pixels(4.000244140625))).toBe(false);
    expect(isWheelNotch(pixels(4.000244140625, 0))).toBe(false);
  });
});

/// A scroller with layout: 1000px of content in a 200px view, and the listeners it was given.
function standIn() {
  const listeners = new Map<string, Set<(event: unknown) => void>>();
  const page = {
    added: new Map<string, number>(),
    addEventListener: (name: string) => page.added.set(name, (page.added.get(name) ?? 0) + 1),
    removeEventListener: (name: string) => page.added.set(name, (page.added.get(name) ?? 0) - 1),
    getComputedStyle: () => ({ overflowY: "auto", overflowX: "hidden" }),
  };
  /// The document: whether it is hidden, and its visibility listeners.
  const doc = {
    defaultView: page,
    hidden: false,
    visibility: new Set<() => void>(),
    addEventListener: (name: string, listener: () => void) =>
      name === "visibilitychange" && doc.visibility.add(listener),
    removeEventListener: (name: string, listener: () => void) =>
      name === "visibilitychange" && doc.visibility.delete(listener),
    hide() {
      doc.hidden = true;
      // A Set may lose the entry being visited: stop() takes the listener off as it runs.
      for (const listener of doc.visibility) listener();
    },
  };
  let top = 400;
  const scroller = {
    /// Kept inside the content, as a browser keeps it (a reply that shrinks pulls it back).
    get scrollTop() {
      return Math.max(0, Math.min(top, scroller.scrollHeight - scroller.clientHeight));
    },
    set scrollTop(value: number) {
      top = Math.max(0, Math.min(value, scroller.scrollHeight - scroller.clientHeight));
    },
    scrollHeight: 1000,
    clientHeight: 200,
    scrollWidth: 300,
    clientWidth: 300,
    ownerDocument: doc,
    getAttribute: () => null,
    addEventListener: (name: string, listener: (event: unknown) => void) => {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name)!.add(listener);
    },
    removeEventListener: (name: string, listener: (event: unknown) => void) => listeners.get(name)?.delete(listener),
    /// A wheel event dispatched on it (a forwarded copy) reaches its wheel listeners, over itself.
    dispatchEvent: (event: Event) => {
      if (event.type === "wheel") {
        Object.defineProperty(event, "composedPath", { value: () => [scroller] });
        for (const listener of listeners.get("wheel") ?? []) listener(event);
      }
      return !event.defaultPrevented;
    },
    listening: (name: string) => listeners.get(name)?.size ?? 0,
    wheel(init: Partial<WheelEvent> & { wheelDeltaY?: number; over?: unknown }) {
      let prevented = false;
      const event = {
        deltaX: 0,
        deltaMode: 0,
        cancelable: true,
        defaultPrevented: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false,
        altKey: false,
        composedPath: () => (init.over ? [init.over, scroller] : [scroller]),
        preventDefault: () => (prevented = true),
        ...init,
      };
      for (const listener of listeners.get("wheel") ?? []) listener(event);
      return prevented;
    },
  };
  return { scroller, page, doc };
}

/// One macOS WebKit notch up (100px) and one down.
const UP = { deltaY: -100.006103515625, wheelDeltaY: 300 };
const DOWN = { deltaY: 100.006103515625, wheelDeltaY: -300 };

describe("installWheelGlide", () => {
  let frames: Map<number, (now: number) => void>;
  let next = 0;
  let now = 0;
  const saved = { raf: globalThis.requestAnimationFrame, caf: globalThis.cancelAnimationFrame };
  beforeEach(() => {
    frames = new Map();
    now = 0;
    globalThis.requestAnimationFrame = ((callback: (now: number) => void) => {
      frames.set(++next, callback);
      return next;
    }) as typeof requestAnimationFrame;
    globalThis.cancelAnimationFrame = ((id: number) => frames.delete(id)) as typeof cancelAnimationFrame;
  });
  afterEach(() => {
    globalThis.requestAnimationFrame = saved.raf;
    globalThis.cancelAnimationFrame = saved.caf;
  });
  /// Runs the pending frames `count` times, 16ms apart.
  const run = (count: number) => {
    for (let index = 0; index < count; index += 1) {
      now += 16;
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(now);
    }
  };
  const setup = () => {
    const { scroller, page, doc } = standIn();
    const glide = installWheelGlide(scroller as unknown as HTMLElement);
    return { scroller, page, doc, glide };
  };

  test("a notch glides over several frames to its distance, and the loop ends there", () => {
    const { scroller, page } = setup();
    expect(scroller.wheel(UP)).toBe(true);
    expect(scroller.scrollTop).toBe(400);
    run(2);
    expect(scroller.scrollTop).toBeLessThan(400);
    expect(scroller.scrollTop).toBeGreaterThan(300);
    run(20);
    expect(Math.round(scroller.scrollTop)).toBe(300);
    expect(frames.size).toBe(0);
    expect(page.added.get("pointerdown")).toBe(0);
  });

  test("a wheel over a row that scrolls on its own ends the glide where it is", () => {
    const { scroller } = setup();
    scroller.wheel(UP);
    run(3);
    const at = scroller.scrollTop;
    const nested = {
      scrollHeight: 900,
      clientHeight: 100,
      scrollWidth: 10,
      clientWidth: 10,
      getAttribute: () => null,
      ownerDocument: scroller.ownerDocument,
    };
    expect(scroller.wheel({ ...UP, over: nested })).toBe(false);
    run(20);
    expect(scroller.scrollTop).toBe(at);
    expect(frames.size).toBe(0);
  });

  test("a trackpad, a modified or a sideways wheel ends the glide where it is", () => {
    for (const other of [
      { deltaY: -7, wheelDeltaY: 21 },
      { ...UP, metaKey: true },
      { ...UP, shiftKey: true },
      { ...UP, altKey: true },
      { deltaX: 300, deltaY: 1 },
      // As much sideways as down: diagonal, the engine's (as wheelPassThrough leaves it).
      { ...UP, deltaX: 100.006103515625 },
    ]) {
      const { scroller } = setup();
      scroller.wheel(UP);
      run(3);
      const at = scroller.scrollTop;
      expect(scroller.wheel(other)).toBe(false);
      run(20);
      expect([other, scroller.scrollTop]).toEqual([other, at]);
    }
  });

  test("stop() ends a glide in flight (Jump to latest, another chat), and the next notch starts afresh", () => {
    const { scroller, glide } = setup();
    scroller.wheel(UP);
    run(3);
    const at = scroller.scrollTop;
    glide.stop();
    run(20);
    expect(scroller.scrollTop).toBe(at);
    scroller.wheel(DOWN);
    run(30);
    expect(Math.round(scroller.scrollTop)).toBe(Math.round(at + 100.006103515625));
  });

  test("a scroller hidden mid-glide ends it", () => {
    const { scroller, page } = setup();
    scroller.wheel(UP);
    run(3);
    const at = scroller.scrollTop;
    scroller.clientHeight = 0;
    run(1);
    expect(frames.size).toBe(0);
    expect(page.added.get("keydown")).toBe(0);
    scroller.clientHeight = 200;
    run(20);
    expect(scroller.scrollTop).toBe(at);
  });

  test("a glide to the bottom follows a reply that grows meanwhile, to the new bottom", () => {
    const { scroller } = setup();
    // 50px above the bottom (800): a notch down goes to the bottom.
    scroller.scrollTop = 750;
    expect(scroller.wheel(DOWN)).toBe(true);
    run(3);
    // The streaming reply grows by 60px mid-glide.
    scroller.scrollHeight = 1060;
    run(20);
    expect(Math.round(scroller.scrollTop)).toBe(860);
    expect(frames.size).toBe(0);
  });

  test("a glide short of the bottom keeps its own distance when the reply grows", () => {
    const { scroller } = setup();
    scroller.scrollTop = 500;
    scroller.wheel(DOWN);
    run(3);
    scroller.scrollHeight = 1060;
    run(20);
    expect(Math.round(scroller.scrollTop)).toBe(600);
  });

  test("a notch and its reverse before the next frame cancel out: the view stays, and the engine moves nothing", () => {
    const { scroller } = setup();
    expect(scroller.wheel(DOWN)).toBe(true);
    // The reverse comes in the same input batch: taken too, so the engine does not apply it at once.
    expect(scroller.wheel(UP)).toBe(true);
    expect(frames.size).toBe(0);
    run(20);
    expect(scroller.scrollTop).toBe(400);
  });

  test("a reverse notch mid-glide heads back to where the glide began", () => {
    const { scroller } = setup();
    scroller.wheel(DOWN);
    run(3);
    expect(scroller.wheel(UP)).toBe(true);
    run(30);
    expect(Math.round(scroller.scrollTop)).toBe(400);
    expect(frames.size).toBe(0);
  });

  test("a reply that shrinks mid-glide ends the glide at the new bottom", () => {
    const { scroller } = setup();
    // Headed for the bottom (800), and the content shrinks to a bottom of 760.
    scroller.scrollTop = 750;
    scroller.wheel(DOWN);
    run(2);
    scroller.scrollHeight = 960;
    run(20);
    expect(scroller.scrollTop).toBe(760);
    expect(frames.size).toBe(0);
    // Short of the bottom, and the content shrinks under the glide's target: it ends at the bottom.
    const short = setup().scroller;
    short.wheel(DOWN);
    run(2);
    short.scrollHeight = 650;
    run(20);
    expect(short.scrollTop).toBe(450);
    expect(frames.size).toBe(0);
  });

  test("a diagonal notch, as much sideways as down, is the engine's", () => {
    const { scroller } = setup();
    expect(scroller.wheel({ ...DOWN, deltaX: -100.006103515625 })).toBe(false);
    run(20);
    expect(scroller.scrollTop).toBe(400);
    expect(frames.size).toBe(0);
  });

  test("a page hidden mid-glide ends it at once: no frame is left for its return", () => {
    const { scroller, page, doc } = setup();
    scroller.wheel(UP);
    run(3);
    const at = scroller.scrollTop;
    expect(doc.visibility.size).toBe(1);
    doc.hide();
    // WebKit holds a hidden page's frames: the glide cannot wait for one to end.
    expect(frames.size).toBe(0);
    expect(doc.visibility.size).toBe(0);
    expect(page.added.get("keydown")).toBe(0);
    // Shown again a while later, the old glide does not jump to its end.
    now += 5_000;
    doc.hidden = false;
    run(20);
    expect(scroller.scrollTop).toBe(at);
  });

  test("remove() with a frame pending cancels it and takes every listener off", () => {
    const { scroller, page, doc, glide } = setup();
    scroller.wheel(UP);
    run(2);
    expect(frames.size).toBe(1);
    glide.remove();
    expect(frames.size).toBe(0);
    expect(scroller.listening("wheel")).toBe(0);
    expect(scroller.listening("scroll")).toBe(0);
    for (const name of ["pointerdown", "touchstart", "keydown"])
      expect([name, page.added.get(name)]).toEqual([name, 0]);
    expect(doc.visibility.size).toBe(0);
  });
});

/// The WheelEvent a page makes (bun has none): the fields forwardWheel copies.
class StandInWheel extends Event {
  deltaX = 0;
  deltaY = 0;
  deltaMode = 0;
  ctrlKey = false;
  metaKey = false;
  shiftKey = false;
  altKey = false;
  wheelDeltaY?: number;
  constructor(type: string, init: Record<string, unknown> = {}) {
    super(type, init);
    Object.assign(this, init);
  }
}

describe("forwardWheel", () => {
  let frames: Map<number, (now: number) => void>;
  let next = 0;
  let now = 0;
  const saved = {
    raf: globalThis.requestAnimationFrame,
    caf: globalThis.cancelAnimationFrame,
    wheel: (globalThis as { WheelEvent?: unknown }).WheelEvent,
  };
  beforeEach(() => {
    frames = new Map();
    globalThis.requestAnimationFrame = ((callback: (now: number) => void) => {
      frames.set(++next, callback);
      return next;
    }) as typeof requestAnimationFrame;
    globalThis.cancelAnimationFrame = ((id: number) => frames.delete(id)) as typeof cancelAnimationFrame;
    (globalThis as { WheelEvent?: unknown }).WheelEvent = StandInWheel;
  });
  afterEach(() => {
    globalThis.requestAnimationFrame = saved.raf;
    globalThis.cancelAnimationFrame = saved.caf;
    (globalThis as { WheelEvent?: unknown }).WheelEvent = saved.wheel;
  });
  const run = (count: number) => {
    for (let index = 0; index < count; index += 1) {
      now += 16;
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(now);
    }
  };
  /// The transcript with its glide, and the wheels it heard (the copies forwarded to it).
  const setup = () => {
    const { scroller } = standIn();
    installWheelGlide(scroller as unknown as HTMLElement);
    const heard: number[] = [];
    scroller.addEventListener("wheel", (event) => heard.push((event as WheelEvent).deltaY));
    return { scroller, heard };
  };
  const over = (init: Record<string, unknown>) => new StandInWheel("wheel", { cancelable: true, ...init });

  test("a forwarded notch glides as it does over the transcript", () => {
    const { scroller } = setup();
    forwardWheel(scroller as unknown as HTMLElement, over(UP) as unknown as WheelEvent);
    // Not moved at once: the glide took the copy.
    expect(scroller.scrollTop).toBe(400);
    run(30);
    expect(Math.round(scroller.scrollTop)).toBe(300);
  });

  test("a forwarded trackpad scroll moves the transcript at once and ends a glide in flight", () => {
    const { scroller } = setup();
    forwardWheel(scroller as unknown as HTMLElement, over(UP) as unknown as WheelEvent);
    run(3);
    const at = scroller.scrollTop;
    forwardWheel(scroller as unknown as HTMLElement, over({ deltaY: -40, wheelDeltaY: 120 }) as unknown as WheelEvent);
    expect(scroller.scrollTop).toBe(at - 40);
    run(20);
    expect(scroller.scrollTop).toBe(at - 40);
    expect(frames.size).toBe(0);
  });

  test("a forwarded pinch (ctrl) is left alone: the transcript hears nothing and does not move", () => {
    const { scroller, heard } = setup();
    forwardWheel(scroller as unknown as HTMLElement, over({ ...UP, ctrlKey: true }) as unknown as WheelEvent);
    run(20);
    expect(heard).toEqual([]);
    expect(scroller.scrollTop).toBe(400);
  });

  test("a forwarded modified notch is heard, scrolls nothing, and ends a glide in flight", () => {
    for (const modifier of ["shiftKey", "altKey", "metaKey"]) {
      const { scroller, heard } = setup();
      forwardWheel(scroller as unknown as HTMLElement, over(DOWN) as unknown as WheelEvent);
      run(3);
      const at = scroller.scrollTop;
      forwardWheel(scroller as unknown as HTMLElement, over({ ...DOWN, [modifier]: true }) as unknown as WheelEvent);
      run(20);
      expect([modifier, heard.length, scroller.scrollTop]).toEqual([modifier, 2, at]);
    }
  });
});
