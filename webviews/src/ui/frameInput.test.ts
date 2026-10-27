import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  FrameInputQueue,
  KEY_TO_PAINT_BOUNDS_MS,
  KEY_TO_PAINT_REPORT_MS,
  KeyToPaintProbe,
  frameInputQueue,
  type FrameScheduler,
  type KeyToPaintReport,
} from "./frameInput";
import { trackPressRelease } from "./pressRelease";

/** Frames that run only when the test says a frame came. */
class FakeFrames implements FrameScheduler {
  private next = 1;
  private callbacks = new Map<number, (time: number) => void>();
  requests = 0;

  request = (callback: (time: number) => void) => {
    this.requests += 1;
    const handle = this.next++;
    this.callbacks.set(handle, callback);
    return handle;
  };

  cancel = (handle: number) => {
    this.callbacks.delete(handle);
  };

  get waiting() {
    return this.callbacks.size;
  }

  frame(time = 0) {
    const due = [...this.callbacks.values()];
    this.callbacks.clear();
    for (const callback of due) callback(time);
  }
}

describe("FrameInputQueue", () => {
  test("N moves in a frame make one call, with the newest value and the count", () => {
    const frames = new FakeFrames();
    const queue = new FrameInputQueue(frames);
    const calls: Array<[number, number]> = [];
    const moves = queue.stream((x: number, coalesced) => calls.push([x, coalesced]));
    for (let x = 1; x <= 40; x++) moves.push(x);
    expect(calls).toEqual([]);
    expect(frames.requests).toBe(1);
    frames.frame();
    expect(calls).toEqual([[40, 40]]);
    // Nothing held: the next frame asks nothing and calls nothing.
    expect(frames.waiting).toBe(0);
    frames.frame();
    expect(calls).toEqual([[40, 40]]);
  });

  test("a merge rule adds up a frame's wheel deltas", () => {
    const frames = new FakeFrames();
    const queue = new FrameInputQueue(frames);
    const calls: number[] = [];
    const wheel = queue.stream(
      (pixels: number) => calls.push(pixels),
      (held, next) => held + next,
    );
    for (const delta of [3, 4, -2, 10]) wheel.push(delta);
    frames.frame();
    expect(calls).toEqual([15]);
  });

  test("streams share one frame request and deliver in the order they first got a value", () => {
    const frames = new FakeFrames();
    const queue = new FrameInputQueue(frames);
    const order: string[] = [];
    const a = queue.stream((value: string) => order.push(value));
    const b = queue.stream((value: string) => order.push(value));
    b.push("b1");
    a.push("a1");
    b.push("b2");
    expect(frames.requests).toBe(1);
    frames.frame();
    expect(order).toEqual(["b2", "a1"]);
  });

  test("flush delivers at once and cancels the frame; cancel drops the value", () => {
    const frames = new FakeFrames();
    const queue = new FrameInputQueue(frames);
    const calls: number[] = [];
    const moves = queue.stream((x: number) => calls.push(x));
    moves.push(1);
    moves.push(2);
    moves.flush();
    expect(calls).toEqual([2]);
    expect(moves.pending).toBe(false);
    moves.push(3);
    moves.cancel();
    queue.flush();
    expect(frames.waiting).toBe(0);
    frames.frame();
    expect(calls).toEqual([2]);
  });

  test("a press flushes the held moves before any handler sees it", () => {
    const dom = new JSDOM("<!doctype html><body><div></div></body>", { pretendToBeVisual: true });
    const win = dom.window as unknown as Window;
    const seen: string[] = [];
    const moves = frameInputQueue(win).stream((x: number) => seen.push(`move ${x}`));
    const target = dom.window.document.querySelector("div")!;
    target.addEventListener("mousedown", () => seen.push("down"));
    moves.push(5);
    moves.push(9);
    target.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true }));
    expect(seen).toEqual(["move 9", "down"]);
    expect(frameInputQueue(win)).toBe(frameInputQueue(win));
  });
});

/** A probe with fake frames, ticks and clock; `key(at)` sends a keydown stamped `at`. */
function probeHarness() {
  const frames = new FakeFrames();
  const ticks: Array<() => void> = [];
  const listeners = new Set<EventListenerOrEventListenerObject>();
  const posts: KeyToPaintReport[] = [];
  let now = 0;
  const probe = new KeyToPaintProbe({
    target: {
      addEventListener: (_type: string, listener: EventListenerOrEventListenerObject | null) => {
        if (listener) listeners.add(listener);
      },
      removeEventListener: (_type: string, listener: EventListenerOrEventListenerObject | null) => {
        if (listener) listeners.delete(listener);
      },
    },
    frames,
    tick: (callback) => ticks.push(callback),
    now: () => now,
    post: (report) => posts.push(report),
  });
  const key = (at: number) => {
    const event = { type: "keydown", timeStamp: at } as Event;
    for (const listener of listeners)
      if (typeof listener === "function") listener(event);
      else listener.handleEvent(event);
  };
  /** The frame comes at `frameAt`, and its task after it at `paintedAt`. */
  const paint = (frameAt: number, paintedAt: number) => {
    now = frameAt;
    frames.frame(frameAt);
    now = paintedAt;
    for (const tick of ticks.splice(0)) tick();
  };
  return {
    probe,
    frames,
    ticks,
    listeners,
    posts,
    key,
    paint,
    setNow: (at: number) => (now = at),
  };
}

describe("KeyToPaintProbe", () => {
  test("off: no listener, no frame, no post", () => {
    const h = probeHarness();
    expect(h.listeners.size).toBe(0);
    h.key(1);
    h.paint(KEY_TO_PAINT_REPORT_MS * 2, KEY_TO_PAINT_REPORT_MS * 2 + 1);
    expect(h.frames.requests).toBe(0);
    expect(h.posts).toEqual([]);
    // On, then off again: the listener goes, and a key asks nothing.
    h.probe.setEnabled(true);
    expect(h.listeners.size).toBe(1);
    h.probe.setEnabled(false);
    expect(h.listeners.size).toBe(0);
    h.key(2);
    expect(h.frames.requests).toBe(0);
  });

  test("a key counts from its timestamp to the task after the next frame", () => {
    const h = probeHarness();
    h.probe.setEnabled(true);
    h.key(100);
    h.key(104);
    // Two keys, one frame.
    expect(h.frames.requests).toBe(1);
    h.paint(110, 112);
    // Under 10 s since the probe came on: held, not posted.
    expect(h.posts).toEqual([]);
    h.setNow(KEY_TO_PAINT_REPORT_MS + 1);
    h.key(KEY_TO_PAINT_REPORT_MS + 1);
    h.paint(KEY_TO_PAINT_REPORT_MS + 20, KEY_TO_PAINT_REPORT_MS + 41);
    expect(h.posts.length).toBe(1);
    const report = h.posts[0]!;
    expect(report.count).toBe(3);
    // 12 ms, 8 ms and 40 ms.
    expect(report.sum_ms).toBe(60);
    expect(report.max_ms).toBe(40);
    expect(report.bounds_ms).toEqual([...KEY_TO_PAINT_BOUNDS_MS]);
    const bucket = (ms: number) => KEY_TO_PAINT_BOUNDS_MS.findIndex((bound) => ms <= bound);
    const expected: number[] = Array.from({ length: KEY_TO_PAINT_BOUNDS_MS.length + 1 }, () => 0);
    for (const ms of [12, 8, 40]) expected[bucket(ms)] += 1;
    expect(report.counts).toEqual(expected);
    // Numbers only: no key, no text.
    for (const [name, value] of Object.entries(report))
      if (name !== "kind") expect(typeof value === "number" || Array.isArray(value)).toBe(true);
    // The next window starts empty, and posts no sooner than 10 s later.
    h.key(KEY_TO_PAINT_REPORT_MS + 50);
    h.paint(KEY_TO_PAINT_REPORT_MS + 60, KEY_TO_PAINT_REPORT_MS + 61);
    expect(h.posts.length).toBe(1);
  });

  test("a frame asked for before the probe went off records nothing", () => {
    const h = probeHarness();
    h.probe.setEnabled(true);
    h.key(1);
    h.probe.setEnabled(false);
    h.probe.setEnabled(true);
    h.paint(KEY_TO_PAINT_REPORT_MS * 3, KEY_TO_PAINT_REPORT_MS * 3 + 1);
    expect(h.ticks.length).toBe(0);
    expect(h.posts).toEqual([]);
  });
});

describe("image viewer wheel frames", () => {
  test("a frame's pan wheels add up to one view change", async () => {
    const { applyWheel, mergeWheel } = await import("../agent-session/acpmux/conversation/ImageViewer");
    const frames = new FakeFrames();
    const queue = new FrameInputQueue(frames);
    let view = { scale: 2, x: 0, y: 0 };
    let changes = 0;
    const wheels = queue.stream((wheel: Parameters<typeof applyWheel>[1]) => {
      changes += 1;
      view = applyWheel(view, wheel);
    }, mergeWheel);
    const point = { x: 0, y: 0 };
    for (let index = 0; index < 10; index++) wheels.push({ zoom: 0, x: 1, y: 2, point });
    frames.frame();
    expect(changes).toBe(1);
    expect(view).toEqual({ scale: 2, x: -10, y: -20 });
    // At the fitted size a scroll does not pan.
    expect(applyWheel({ scale: 1, x: 0, y: 0 }, { zoom: 0, x: 5, y: 5, point })).toEqual({ scale: 1, x: 0, y: 0 });
  });
});

describe("press-drag-release hover", () => {
  test("a frame's moves make one hit test, and the release hands the held one over first", () => {
    const dom = new JSDOM('<!doctype html><body><button>Open</button><div role="menuitem">Row</div></body>', {
      pretendToBeVisual: true,
    });
    const doc = dom.window.document;
    const trigger = doc.querySelector("button")!;
    const row = doc.querySelector<HTMLElement>('[role="menuitem"]')!;
    const hits: number[] = [];
    // jsdom has no layout: every point is over the row.
    doc.elementFromPoint = (x: number) => {
      hits.push(x);
      return row;
    };
    const seen: string[] = [];
    trackPressRelease(
      { pointerId: 1, clientX: 0, clientY: 0, currentTarget: trigger },
      { hover: () => seen.push("hover"), pick: () => seen.push("pick"), end: () => seen.push("end") },
    );
    const pointer = (type: string, x: number) => {
      const event = new dom.window.MouseEvent(type, { bubbles: true, clientX: x, clientY: 0 });
      Object.defineProperty(event, "pointerId", { value: 1 });
      trigger.dispatchEvent(event);
    };
    for (const x of [10, 20, 30, 40]) pointer("pointermove", x);
    expect(hits).toEqual([]);
    frameInputQueue(dom.window as unknown as Window).flush();
    expect(hits).toEqual([40]);
    expect(seen).toEqual(["hover"]);
    pointer("pointermove", 50);
    pointer("pointerup", 50);
    expect(seen).toEqual(["hover", "hover", "pick", "end"]);
  });
});
