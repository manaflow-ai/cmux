// Which wheel events are a mouse wheel's notch (wheelGlide.ts): the values each engine dispatches.
// And where a glide stops: a stand-in scroller and frame clock, so each stop is checked frame by
// frame (the browser tests cover the motion itself).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { installWheelGlide, isWheelNotch } from "./wheelGlide";

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
  const scroller = {
    scrollTop: 400,
    scrollHeight: 1000,
    clientHeight: 200,
    scrollWidth: 300,
    clientWidth: 300,
    ownerDocument: { defaultView: page },
    getAttribute: () => null,
    addEventListener: (name: string, listener: (event: unknown) => void) => {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name)!.add(listener);
    },
    removeEventListener: (name: string, listener: (event: unknown) => void) => listeners.get(name)?.delete(listener),
    dispatchEvent: () => true,
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
  return { scroller, page };
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
    const { scroller, page } = standIn();
    const glide = installWheelGlide(scroller as unknown as HTMLElement);
    return { scroller, page, glide };
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

  test("remove() with a frame pending cancels it and takes every listener off", () => {
    const { scroller, page, glide } = setup();
    scroller.wheel(UP);
    run(2);
    expect(frames.size).toBe(1);
    glide.remove();
    expect(frames.size).toBe(0);
    expect(scroller.listening("wheel")).toBe(0);
    expect(scroller.listening("scroll")).toBe(0);
    for (const name of ["pointerdown", "touchstart", "keydown"])
      expect([name, page.added.get(name)]).toEqual([name, 0]);
  });
});
