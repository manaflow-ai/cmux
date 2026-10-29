// The page clock: one aligned setTimeout chain per page and granularity, however
// many labels read it; none while the page is hidden or nobody subscribes; one tick on show when a
// boundary passed while hidden.
import { afterEach, describe, expect, test } from "bun:test";
import { act, createElement } from "react";
import { type LifecycleDocument, PageLifecycle } from "../src/pages/shared/pageLifecycle";
import { type ClockTimers, PageClock, clockFloor, pageClockFor } from "../src/ui/pageClock";
import { useNow } from "../src/ui/useNow";

class FakeDocument implements LifecycleDocument {
  visibilityState = "visible";
  private readonly listeners = new Map<string, Set<(event: { type: string }) => void>>();

  addEventListener(type: string, listener: (event: { type: string }) => void): void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: (event: { type: string }) => void): void {
    this.listeners.get(type)?.delete(listener);
  }

  listenerCount(): number {
    let count = 0;
    for (const set of this.listeners.values()) count += set.size;
    return count;
  }

  hide(): void {
    this.visibilityState = "hidden";
    for (const listener of this.listeners.get("visibilitychange") ?? []) listener({ type: "visibilitychange" });
  }

  show(): void {
    this.visibilityState = "visible";
    for (const listener of this.listeners.get("visibilitychange") ?? []) listener({ type: "visibilitychange" });
  }
}

/** One-shot timers on a clock the test moves. `early` fires each timer longer than `early` that many
    ms before its due (a coarse timer that rounds down). */
class FakeTimers implements ClockTimers {
  started = 0;
  readonly delays: number[] = [];
  private next = 1;
  private readonly pending = new Map<number, { due: number; callback: () => void }>();

  constructor(
    private time: number,
    private readonly early = 0,
  ) {}

  now(): number {
    return this.time;
  }

  after(ms: number, callback: () => void): unknown {
    this.started += 1;
    this.delays.push(ms);
    const id = this.next++;
    this.pending.set(id, { due: this.time + ms - (ms > this.early ? this.early : 0), callback });
    return id;
  }

  cancel(handle: unknown): void {
    this.pending.delete(handle as number);
  }

  get live(): number {
    return this.pending.size;
  }

  /** Moves the clock by `ms`, running each timer when it comes due (less `early`). */
  advance(ms: number): void {
    const end = this.time + ms;
    for (;;) {
      let first: [number, { due: number; callback: () => void }] | undefined;
      for (const entry of this.pending) if (!first || entry[1].due < first[1].due) first = entry;
      if (!first) break;
      const fireAt = Math.max(this.time, first[1].due);
      if (fireAt > end) break;
      this.pending.delete(first[0]);
      this.time = fireAt;
      first[1].callback();
    }
    this.time = end;
  }
}

/** A visible page's clock whose wall clock starts off any boundary. */
function makeClock(start = 1_234_567, early = 0) {
  const doc = new FakeDocument();
  const lifecycle = new PageLifecycle(doc);
  const timers = new FakeTimers(start, early);
  return { doc, lifecycle, timers, clock: new PageClock(lifecycle, timers) };
}

describe("pageClock", () => {
  test("5 subscribers at 1 s share 1 timer", () => {
    const { timers, clock } = makeClock();
    const ticks = [0, 0, 0, 0, 0];
    const stops = ticks.map((_, index) => clock.subscribe("second", () => (ticks[index] += 1)));
    expect(timers.live).toBe(1);
    expect(timers.started).toBe(1);
    timers.advance(5000);
    expect(ticks).toEqual([5, 5, 5, 5, 5]);
    expect(timers.live).toBe(1);
    stops.slice(0, 4).forEach((stop) => stop());
    expect(timers.live).toBe(1);
    stops[4]?.();
    expect(timers.live).toBe(0);
  });

  test("each wake lands on the wall-clock boundary", () => {
    const { timers, clock } = makeClock(1_234_567);
    const at: number[] = [];
    clock.subscribe("second", () => at.push(timers.now()));
    expect(timers.delays[0]).toBe(433);
    timers.advance(3000);
    expect(at).toEqual([1_235_000, 1_236_000, 1_237_000]);
    expect(clock.now()).toBe(1_237_000);
  });

  test("the minute granularity has its own aligned timer", () => {
    const { timers, clock } = makeClock(90_000);
    let seconds = 0;
    const at: number[] = [];
    clock.subscribe("second", () => (seconds += 1));
    clock.subscribe("minute", () => at.push(timers.now()));
    expect(timers.live).toBe(2);
    timers.advance(120_000);
    expect(at).toEqual([120_000, 180_000]);
    expect(seconds).toBe(120);
    expect(clock.now()).toBe(210_000);
  });

  test("the minute granularity reads the same time as the second one, so an elapsed time never goes back", () => {
    const { timers, clock } = makeClock(4_000_000);
    timers.advance(500);
    const start = timers.now();
    const elapsed = () => Math.max(0, clock.now() - start);
    const stopSecond = clock.subscribe("second", () => undefined);
    timers.advance(61_000);
    const atSecond = elapsed();
    expect(atSecond).toBe(60_500);
    const stopMinute = clock.subscribe("minute", () => undefined);
    stopSecond();
    expect(elapsed()).toBeGreaterThanOrEqual(atSecond);
    timers.advance(60_000);
    expect(elapsed()).toBe(120_500);
    stopMinute();
  });

  test("hidden runs 0 timers; showing ticks once when a boundary passed", () => {
    const { doc, timers, clock } = makeClock();
    let ticks = 0;
    clock.subscribe("second", () => (ticks += 1));
    clock.subscribe("second", () => undefined);
    doc.hide();
    expect(timers.live).toBe(0);
    timers.advance(10_000);
    expect(ticks).toBe(0);
    doc.show();
    expect(ticks).toBe(1);
    expect(timers.live).toBe(1);
    const at = timers.now();
    expect(timers.delays.at(-1)).toBe(clockFloor(at, "second") + 1000 - at);
    timers.advance(1000);
    expect(ticks).toBe(2);
  });

  test("a hide and show inside one period does not tick", () => {
    const { doc, timers, clock } = makeClock(5_000_100);
    let ticks = 0;
    clock.subscribe("second", () => (ticks += 1));
    doc.hide();
    timers.advance(300);
    doc.show();
    expect(ticks).toBe(0);
    expect(timers.live).toBe(1);
  });

  test("subscribing while hidden starts no timer", () => {
    const { doc, timers, clock } = makeClock(7_000_200);
    doc.hide();
    let ticks = 0;
    clock.subscribe("second", () => (ticks += 1));
    expect(timers.started).toBe(0);
    timers.advance(100);
    doc.show();
    expect(ticks).toBe(0);
    expect(timers.live).toBe(1);
  });

  test("the last unsubscribe stops the timer and the lifecycle listeners", () => {
    const { doc, timers, clock } = makeClock();
    const listenersBefore = doc.listenerCount();
    const stop = clock.subscribe("minute", () => undefined);
    expect(doc.listenerCount()).toBeGreaterThan(listenersBefore);
    stop();
    stop();
    expect(timers.live).toBe(0);
    expect(doc.listenerCount()).toBe(listenersBefore);
  });

  test("a timeout that fires early re-arms for the boundary and ticks once there", () => {
    const { timers, clock } = makeClock(2_000_500, 1);
    const at: number[] = [];
    clock.subscribe("second", () => at.push(timers.now()));
    timers.advance(2600);
    expect(at).toEqual([2_001_000, 2_002_000, 2_003_000]);
  });

  test("pageClockFor makes one clock per page", () => {
    const lifecycle = new PageLifecycle(new FakeDocument());
    expect(pageClockFor(lifecycle)).toBe(pageClockFor(lifecycle));
    expect(pageClockFor(new PageLifecycle(new FakeDocument()))).not.toBe(pageClockFor(lifecycle));
  });
});

describe("useNow", () => {
  const scope = globalThis as Record<string, unknown>;
  const saved = new Map<string, unknown>();
  let unmount: (() => void) | undefined;

  afterEach(async () => {
    if (unmount) await act(async () => unmount?.());
    unmount = undefined;
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    saved.clear();
  });

  async function render(
    element: ReturnType<typeof createElement>,
  ): Promise<(next: ReturnType<typeof createElement>) => Promise<void>> {
    const { JSDOM } = await import("jsdom");
    const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
      url: "http://localhost/",
    });
    for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    const { createRoot } = await import("react-dom/client");
    const root = createRoot(dom.window.document.getElementById("root") as unknown as Element);
    await act(async () => root.render(element));
    unmount = () => root.unmount();
    return (next) => act(async () => root.render(next));
  }

  test("five labels re-render on each boundary from one timer, and none while hidden", async () => {
    const { doc, timers, clock } = makeClock(3_000_250);
    const seen: number[][] = [[], [], [], [], []];
    function Label({ index }: { index: number }) {
      seen[index]?.push(useNow("second", { clock }));
      return null;
    }
    await render(
      createElement(
        "div",
        null,
        seen.map((_, index) => createElement(Label, { key: index, index })),
      ),
    );
    expect(seen.map((values) => values.at(-1))).toEqual(Array(5).fill(3_000_000));
    expect(timers.live).toBe(1);

    await act(async () => timers.advance(2000));
    expect(seen.map((values) => values.at(-1))).toEqual(Array(5).fill(3_002_000));
    expect(timers.live).toBe(1);

    await act(async () => doc.hide());
    const renders = seen.map((values) => values.length);
    await act(async () => timers.advance(5000));
    expect(timers.live).toBe(0);
    expect(seen.map((values) => values.length)).toEqual(renders);

    await act(async () => doc.show());
    expect(seen.map((values) => values.at(-1))).toEqual(Array(5).fill(3_007_000));
    expect(timers.live).toBe(1);

    await act(async () => unmount?.());
    unmount = undefined;
    expect(timers.live).toBe(0);
  });

  test("an elapsed label does not go back when it moves from second to minute granularity", async () => {
    const { timers, clock } = makeClock(6_000_500);
    const start = timers.now();
    const elapsed: number[] = [];
    function Elapsed({ granularity }: { granularity: "second" | "minute" }) {
      elapsed.push(Math.max(0, useNow(granularity, { clock }) - start));
      return null;
    }
    const rerender = await render(createElement(Elapsed, { granularity: "second" }));
    await act(async () => timers.advance(61_000));
    const beforeSwitch = elapsed.at(-1) ?? 0;
    expect(beforeSwitch).toBe(60_500);

    await rerender(createElement(Elapsed, { granularity: "minute" }));
    expect(elapsed.at(-1) ?? 0).toBeGreaterThanOrEqual(beforeSwitch);
    expect(timers.live).toBe(1);
    await act(async () => timers.advance(60_000));
    expect(elapsed.at(-1)).toBe(120_500);
    expect(elapsed.slice(1).every((value, index) => value >= (elapsed[index] ?? 0))).toBe(true);
  });

  test("enabled false subscribes nothing", async () => {
    const { timers, clock } = makeClock();
    function Label() {
      useNow("minute", { clock, enabled: false });
      return null;
    }
    await render(createElement(Label));
    expect(timers.started).toBe(0);
  });
});
