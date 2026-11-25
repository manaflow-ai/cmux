// The flicker log's `first-load` record (firstLoadWatch.ts): a chat page's first load judged in the field
// as the first-load bench judges it, with no row id or chat text in what it sends.
import { describe, expect, test } from "bun:test";
import type { FrameRecord, FrameRow } from "./firstLoadFrames";
import { firstLoadFields, watchFirstLoad } from "./firstLoadWatch";

const ROWS: FrameRow[] = [
  { id: "user-117", top: 120 },
  { id: "assistant-118", top: 260 },
];
const COMPOSER = { top: 680, height: 96 };
const frame = (t: number, overrides: Partial<FrameRecord> = {}): FrameRecord => ({
  t,
  copyShown: false,
  rows: ROWS,
  composer: COMPOSER,
  scrollTop: 4000,
  ...overrides,
});

describe("first-load record", () => {
  test("a copy that the live page replaces in place records no shift, settled at its first frame", () => {
    expect(
      firstLoadFields([frame(40, { copyShown: true }), frame(56, { copyShown: true }), frame(72), frame(88)]),
    ).toEqual({
      copy: true,
      frames: 4,
      first: 40,
      settled: 40,
      shifts: 0,
      blank: 0,
      why: "",
      painted: -1,
      seen: 0,
      seenWhy: "",
      seenAt: -1,
      seenPx: 0,
    });
  });

  test("only what moved after the host was told the page shows the chat counts as seen", () => {
    const fields = firstLoadFields(
      [
        frame(40),
        frame(56, { composer: { top: 640, height: 136 } }),
        frame(72, { composer: { top: 620, height: 156 } }),
      ],
      60,
    );
    expect(fields?.shifts).toBe(2);
    expect(fields?.painted).toBe(60);
    expect(fields?.seen).toBe(1);
    expect(fields?.seenWhy).toBe("composer top");
    expect(fields?.seenAt).toBe(12);
    expect(fields?.seenPx).toBe(-20);
  });

  test("a composer that moves after the first paint counts, by kind only", () => {
    const fields = firstLoadFields([
      frame(40),
      frame(56, { composer: { top: 640, height: 136 } }),
      frame(72, { composer: { top: 640, height: 136 } }),
    ]);
    expect(fields?.shifts).toBe(1);
    expect(fields?.settled).toBe(56);
    expect(fields?.why).toBe("composer top");
  });

  test("a bottom row replaced names no row id", () => {
    const fields = firstLoadFields([frame(40), frame(56, { rows: [{ id: "assistant-200", top: 300 }] })]);
    expect(fields?.why).toBe("bottom row replaced");
    expect(JSON.stringify(fields)).not.toContain("assistant");
  });

  test("a load that never painted content records nothing", () => {
    expect(firstLoadFields([frame(40, { rows: [] }), frame(56, { rows: [] })])).toBeUndefined();
  });
});

/// A chat page as watchFirstLoad sees it: rows and a composer whose boxes the test moves, a frame clock
/// at 16 ms steps, and timers, frame callbacks and observers it runs itself. It counts the frame and timer
/// callbacks that ran while `counting`, as bench/stability.ts counts a page's wakeups.
class FakePage {
  now = 0;
  rows: FrameRow[] = [];
  composer = { ...COMPOSER };
  readonly state: { visibility: DocumentVisibilityState } = { visibility: "visible" };
  counting = false;
  wakeups = 0;
  records: ReturnType<typeof firstLoadFields>[] = [];
  /// Called before each frame's callbacks: a box that moves with no DOM change (a CSS transition).
  onFrame: (() => void) | undefined;
  private readonly frameQueue = new Map<number, (time: number) => void>();
  private readonly timers = new Map<number, { at: number; run: () => void }>();
  private readonly mutationCallbacks = new Set<() => void>();
  private readonly listeners: { type: string; run: () => void }[] = [];
  private nextId = 1;
  readonly win: Window;

  constructor() {
    const box = (top: number, height: number) => ({ top, height, bottom: top + height });
    const scroller = { scrollTop: 4000, getBoundingClientRect: () => box(0, 800) };
    const listen = (type: string, run: () => void) => this.listeners.push({ type, run });
    const unlisten = (type: string, run: () => void) => {
      const at = this.listeners.findIndex((one) => one.type === type && one.run === run);
      if (at >= 0) this.listeners.splice(at, 1);
    };
    const state = this.state;
    const callbacks = this.mutationCallbacks;
    const doc = {
      get visibilityState() {
        return state.visibility;
      },
      documentElement: {},
      getElementById: () => ({ style: { opacity: "1" } }),
      querySelector: (selector: string) => (selector === ".acpmux-scroll" ? scroller : null),
      querySelectorAll: (selector: string) =>
        selector === ".acpmux-composer-box"
          ? [{ getBoundingClientRect: () => box(this.composer.top, this.composer.height) }]
          : this.rows.map((row) => ({ dataset: { rowId: row.id }, getBoundingClientRect: () => box(row.top, 100) })),
      addEventListener: listen,
      removeEventListener: unlisten,
    };
    class Observer {
      constructor(private readonly run: () => void) {}
      observe() {
        callbacks.add(this.run);
      }
      disconnect() {
        callbacks.delete(this.run);
      }
    }
    this.win = {
      document: doc,
      performance: { now: () => this.now },
      MutationObserver: Observer,
      requestAnimationFrame: (run: (time: number) => void) => {
        const id = this.nextId++;
        this.frameQueue.set(id, run);
        return id;
      },
      cancelAnimationFrame: (id: number) => this.frameQueue.delete(id),
      setTimeout: (run: () => void, ms = 0) => {
        const id = this.nextId++;
        this.timers.set(id, { at: this.now + ms, run });
        return id;
      },
      clearTimeout: (id: number) => this.timers.delete(id),
      addEventListener: listen,
      removeEventListener: unlisten,
    } as unknown as Window;
  }

  /// The DOM changed: what a MutationObserver hears.
  mutate(change: () => void = () => undefined): void {
    change();
    for (const run of this.mutationCallbacks) run();
  }

  dispatch(type: string): void {
    for (const one of this.listeners.filter((listener) => listener.type === type)) one.run();
  }

  /// Runs every timer and frame up to `until` (ms), a frame each 16 ms.
  advanceTo(until: number): void {
    while (this.now < until) {
      const next = Math.min(until, Math.floor(this.now / 16) * 16 + 16);
      for (const [id, timer] of [...this.timers].sort((a, b) => a[1].at - b[1].at)) {
        if (timer.at > next) continue;
        this.timers.delete(id);
        this.now = Math.max(this.now, timer.at);
        if (this.counting) this.wakeups += 1;
        timer.run();
      }
      this.now = next;
      if (next % 16 !== 0 || this.state.visibility !== "visible") continue;
      this.onFrame?.();
      const queued = [...this.frameQueue];
      this.frameQueue.clear();
      for (const [, run] of queued) {
        if (this.counting) this.wakeups += 1;
        run(next);
      }
    }
  }
}

const A_ROWS: FrameRow[] = [
  { id: "user-1", top: 120 },
  { id: "assistant-2", top: 260 },
];
const B_ROWS: FrameRow[] = [
  { id: "user-7", top: 140 },
  { id: "assistant-8", top: 300 },
];

/// A loads at 100 ms, B is selected at 250 ms and paints, and the page is then left as the bench leaves it.
function loadAndSwitch(): FakePage {
  const page = new FakePage();
  watchFirstLoad(page.win, (fields) => page.records.push(fields));
  page.advanceTo(100);
  page.mutate(() => {
    page.rows = A_ROWS;
  });
  page.advanceTo(250);
  page.mutate(() => {
    page.rows = B_ROWS;
  });
  // bench/chat-switch.bench.ts waits until nothing moved for 400 ms after the switch painted.
  page.advanceTo(700);
  return page;
}

describe("first-load watch at rest", () => {
  test("a chat at rest after a switch wakes nothing for the watch in the 5 s window (bench idle_wakeups)", () => {
    const page = loadAndSwitch();
    page.counting = true;
    page.advanceTo(5_700);
    page.counting = false;
    expect(page.wakeups).toBe(0);
  });

  test("the load is still judged, with the switch's replaced bottom row, once the page changes again", () => {
    const page = loadAndSwitch();
    page.advanceTo(7_000);
    page.mutate(); // a minute label ticks
    page.advanceTo(7_100);
    expect(page.records).toHaveLength(1);
    const fields = page.records[0]!;
    expect(fields.first).toBeGreaterThanOrEqual(100);
    expect(fields.first).toBeLessThanOrEqual(120);
    expect(fields.settled).toBeGreaterThanOrEqual(250);
    expect(fields.settled).toBeLessThanOrEqual(270);
    expect(fields.shifts).toBe(1);
    expect(fields.why).toBe("bottom row replaced");
    page.mutate();
    page.advanceTo(9_000);
    expect(page.records).toHaveLength(1);
  });

  test("a composer that keeps moving after one change (a transition) counts each moving frame", () => {
    const page = new FakePage();
    watchFirstLoad(page.win, (fields) => page.records.push(fields));
    page.advanceTo(100);
    page.mutate(() => {
      page.rows = A_ROWS;
    });
    page.advanceTo(300);
    let steps = 3;
    page.onFrame = () => {
      if (steps-- > 0) page.composer = { ...page.composer, top: page.composer.top - 10 };
    };
    page.mutate();
    page.advanceTo(3_000);
    page.state.visibility = "hidden";
    page.dispatch("visibilitychange");
    page.advanceTo(3_100);
    expect(page.records).toHaveLength(1);
    expect(page.records[0]!.shifts).toBe(3);
    expect(page.records[0]!.why).toBe("composer top");
  });
});
