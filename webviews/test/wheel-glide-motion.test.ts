// l10n-allow-file: deterministic wheel and scroll-clock fixtures.
import { expect, test } from "bun:test";
import { installWheelGlide, isWheelNotch } from "../src/agent-session/acpmux/wheelGlide";
import { animateScroll, stopScroll } from "../src/agent-session/acpmux/threadMinimap/scrollMotion";
import { JUMP_CURVE } from "../src/agent-session/acpmux/threadMinimap/model";

function fixture() {
  const saved = [globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] as const;
  const pending = new Map<number, FrameRequestCallback>();
  let handle = 0;
  let now = Math.floor(performance.now());
  const savedNow = performance.now;
  performance.now = () => now;
  globalThis.requestAnimationFrame = (run) => {
    pending.set(++handle, run);
    return handle;
  };
  globalThis.cancelAnimationFrame = (id) => void pending.delete(id);
  let duration = "";
  const page = Object.assign(new EventTarget(), {
    getComputedStyle: () => ({ overflowY: "auto", overflowX: "auto", getPropertyValue: () => duration }),
  });
  const doc = Object.assign(new EventTarget(), { defaultView: page, hidden: false, documentElement: { dataset: {} } });
  let round = Math.round;
  class Scroller extends EventTarget {
    /// The wheel listeners that may cancel the scroll: WebKit sends each wheel to the page first
    /// while there is one.
    cancelling = new Set<unknown>();
    override addEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: AddEventListenerOptions | boolean,
    ) {
      if (type === "wheel" && !(typeof options === "object" && options.passive)) this.cancelling.add(listener);
      super.addEventListener(type, listener, options);
    }
    override removeEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: EventListenerOptions | boolean,
    ) {
      if (type === "wheel") this.cancelling.delete(listener);
      super.removeEventListener(type, listener, options);
    }
    ownerDocument = doc;
    clientHeight = 500;
    scrollHeight = 2500;
    private top = 1000;
    getAttribute() {
      return null;
    }
    get scrollTop() {
      return this.top;
    }
    set scrollTop(value: number) {
      this.top = Math.max(0, Math.min(this.scrollHeight - this.clientHeight, round(value)));
    }
  }
  const box = new Scroller();
  const node = box as unknown as HTMLElement;
  const glide = installWheelGlide(node);
  const wheel = (dy: number, overrides: Record<string, unknown> = {}) => {
    const event = new Event("wheel", { cancelable: true });
    Object.assign(event, { deltaY: dy, deltaX: 0, deltaMode: 1, composedPath: () => [node], ...overrides });
    node.dispatchEvent(event);
    return event.defaultPrevented;
  };
  return {
    node,
    cancelling: () => box.cancelling.size,
    floorOffsets() {
      round = Math.floor;
    },
    motion(value: string) {
      duration = value;
    },
    grow(by: number) {
      box.scrollHeight += by;
    },
    glide,
    doc,
    page,
    wheel,
    pending,
    tick(ms = 20) {
      now += ms;
      const callbacks = [...pending.values()];
      pending.clear();
      for (const callback of callbacks) callback(now);
    },
    finish() {
      this.tick(500);
    },
    restore() {
      glide.remove();
      stopScroll(node);
      [globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] = saved;
      performance.now = savedNow;
    },
  };
}

test("notch classification leaves ambiguous precise input native", () => {
  expect(isWheelNotch({ deltaY: -100, deltaMode: 0, wheelDeltaY: 120 })).toBe(true);
  expect(isWheelNotch({ deltaY: -100.006103515625, deltaMode: 0, wheelDeltaY: 300 })).toBe(true);
  expect(isWheelNotch({ deltaY: -40, deltaMode: 0, wheelDeltaY: 120 })).toBe(false);
  expect(isWheelNotch({ deltaY: -2.5, deltaMode: 0, wheelDeltaY: 7 })).toBe(false);
});

test("accumulated and equal reverse notches preserve their full distance", () => {
  const f = fixture();
  try {
    expect(f.wheel(5)).toBe(true);
    expect(f.wheel(-5)).toBe(true);
    f.finish();
    expect(f.node.scrollTop).toBe(1000);
    expect(f.pending.size).toBe(0);
    f.wheel(5);
    f.tick();
    f.wheel(5);
    f.finish();
    expect(f.node.scrollTop).toBe(1160);
  } finally {
    f.restore();
  }
});

test("row-id anchor correction is retained while the notch adds only its own distance", () => {
  const f = fixture();
  try {
    f.wheel(-10);
    f.tick();
    // The existing prepend anchor owns this write, not the animation.
    f.grow(500);
    f.node.scrollTop += 500;
    f.finish();
    expect(f.node.scrollTop).toBe(1340);
  } finally {
    f.restore();
  }
});

test("a deliberate wheel to the bottom lands at the streamed end, including shrink", () => {
  const f = fixture();
  try {
    f.node.scrollTop = 1950;
    f.wheel(10);
    f.tick();
    f.grow(200);
    f.finish();
    expect(f.node.scrollTop).toBe(2200);
    f.node.scrollTop = 2100;
    f.wheel(10);
    f.tick();
    f.grow(-150);
    f.finish();
    expect(f.node.scrollTop).toBe(2050);
  } finally {
    f.restore();
  }
});

test.each(["keydown", "pointerdown", "touchstart", "precise", "nested", "hidden", "pane", "switch", "remove"])(
  "%s cancels pending motion and leaves no later write",
  (reason) => {
    const f = fixture();
    try {
      f.wheel(-5);
      f.tick();
      const stopped = f.node.scrollTop;
      if (["keydown", "pointerdown", "touchstart"].includes(reason)) f.page.dispatchEvent(new Event(reason));
      else if (reason === "precise") f.wheel(-40, { deltaMode: 0, wheelDeltaY: 120 });
      else if (reason === "nested") {
        const nested = Object.assign(new EventTarget(), {
          ownerDocument: f.doc,
          scrollHeight: 1000,
          clientHeight: 100,
          getAttribute: () => null,
        });
        f.wheel(-5, { composedPath: () => [nested, f.node] });
      } else if (reason === "hidden") {
        f.doc.hidden = true;
        f.doc.dispatchEvent(new Event("visibilitychange"));
      } else if (reason === "pane") Object.defineProperty(f.node, "clientHeight", { value: 0 });
      else if (reason === "switch") f.glide.stop();
      else f.glide.remove();
      f.finish();
      expect(f.node.scrollTop).toBe(stopped);
      expect(f.pending.size).toBe(0);
    } finally {
      f.restore();
    }
  },
);

test("a jump replaces wheel motion on the same clock; old cleanup cannot stop the jump", () => {
  const f = fixture();
  try {
    f.wheel(-5);
    f.tick();
    animateScroll(f.node, () => 1900, 180, JUMP_CURVE);
    f.glide.stop();
    f.finish();
    expect(f.node.scrollTop).toBe(1900);
    expect(f.pending.size).toBe(0);
  } finally {
    f.restore();
  }
});

test("notches honor the host motion speed and a zero duration remains native", () => {
  const f = fixture();
  try {
    f.motion("360ms");
    f.wheel(-10);
    f.tick(180);
    expect(f.node.scrollTop).toBeGreaterThan(840);
    expect(f.pending.size).toBe(1);
    f.tick(180);
    expect(f.node.scrollTop).toBe(840);
    expect(f.pending.size).toBe(0);
    f.motion("0s");
    expect(f.wheel(-10)).toBe(false);
    expect(f.pending.size).toBe(0);
  } finally {
    f.restore();
  }
});

test.each(
  [
    [20, 20, 20, 20, 20, 20, 20, 20, 20],
    [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4],
    [176.57, 4.43],
  ].map((frames) => ({ frames })),
)("subpixel travel is monotonic at every frame cadence (%j)", ({ frames }) => {
  const f = fixture();
  try {
    f.floorOffsets();
    f.wheel(-100.006103515625, { deltaMode: 0, wheelDeltaY: 300 });
    const offsets = [f.node.scrollTop];
    for (const duration of frames) {
      f.tick(duration);
      offsets.push(f.node.scrollTop);
    }
    expect(offsets.slice(1).every((top, index) => top <= offsets[index]!)).toBe(true);
    expect(f.node.scrollTop).toBe(900);
    expect(f.pending.size).toBe(0);
  } finally {
    f.restore();
  }
});

// A wheel listener that may cancel makes WebKit hold every wheel event for the page before it
// scrolls, so a trackpad's scroll stopped while the page was busy, as when an older page of history
// lands (Leo 2026-10-29: "why is it sometimes blocking me from scrolling up further?").
test("precise input scrolls with no cancelling wheel listener; the next notch arms the glide again", () => {
  const f = fixture();
  try {
    // A fresh pane's first notch glides.
    expect(f.wheel(-5)).toBe(true);
    f.finish();
    // A trackpad: no wheel listener may cancel once it is seen, so WebKit scrolls on its own.
    expect(f.wheel(-40, { deltaMode: 0, wheelDeltaY: 120 })).toBe(false);
    expect(f.cancelling()).toBe(0);
    expect(f.wheel(-12, { deltaMode: 0, wheelDeltaY: 36 })).toBe(false);
    expect(f.cancelling()).toBe(0);
    // A mouse again: its first notch scrolls natively and arms the glide; the next one glides.
    expect(f.wheel(-5)).toBe(false);
    expect(f.cancelling()).toBe(1);
    expect(f.wheel(-5)).toBe(true);
    f.finish();
    f.glide.remove();
    expect(f.cancelling()).toBe(0);
  } finally {
    f.restore();
  }
});
