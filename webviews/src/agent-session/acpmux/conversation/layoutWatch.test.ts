// The transcript's layout watch (layoutWatch.ts): what moves in view with no input, append or declared
// move is an event; what is explained is not; a page at rest wakes nothing for it.
import { afterEach, describe, expect, test } from "bun:test";
import {
  clockSeconds,
  idTail,
  installLayoutWatch,
  layoutWatch,
  LayoutWatcher,
  layoutWatchWanted,
  resetLayoutWatchForTests,
  retainLayoutWatch,
  INPUT_MS,
} from "./layoutWatch";

type FakeRow = { id: string; top: number; height: number; kind?: string; opacity?: number; element?: object };

const box = (top: number, height: number, left = 0, width = 600) => ({
  top,
  height,
  bottom: top + height,
  left,
  width,
  right: left + width,
});

function classes(names: string[]) {
  return Object.assign([...names], { contains: (name: string) => names.includes(name) });
}

/// A chat page as the watch sees it: rows whose boxes the test moves in a 800 px scroller, a frame clock
/// at 16 ms steps, and frame callbacks, posted messages (after the frame's paint), timers and observers
/// it runs itself. It counts every callback the watch gets while `counting`, as bench/stability.ts counts
/// a page's wakeups.
class FakePage {
  now = 0;
  rows: FakeRow[] = [];
  counting = false;
  wakeups = 0;
  private readonly elements = new Map<string, object>();
  private readonly frameQueue = new Map<number, () => void>();
  private readonly messages: (() => void)[] = [];
  private readonly timers = new Map<number, { at: number; run: () => void }>();
  private readonly mutationCallbacks = new Set<(records: unknown[]) => void>();
  private readonly resizeCallbacks = new Set<() => void>();
  private readonly listeners: { type: string; run: (event: Event) => void }[] = [];
  private nextId = 1;
  readonly win: Window;

  constructor() {
    const scroller = {
      scrollTop: 0,
      getBoundingClientRect: () => box(0, 800),
      querySelectorAll: () => [] as unknown[],
      querySelector: () => null,
    };
    const listen = (type: string, run: (event: Event) => void) => this.listeners.push({ type, run });
    const unlisten = (type: string, run: (event: Event) => void) => {
      const at = this.listeners.findIndex((one) => one.type === type && one.run === run);
      if (at >= 0) this.listeners.splice(at, 1);
    };
    const page = this;
    const doc = {
      visibilityState: "visible",
      documentElement: {},
      getElementById: () => ({ style: { opacity: "1" } }),
      querySelector: (selector: string) => (selector === ".acpmux-scroll" ? scroller : null),
      querySelectorAll: (selector: string) =>
        selector === ".acpmux-composer-box" ? [] : this.rows.map((row) => this.elementOf(row)),
      addEventListener: listen,
      removeEventListener: unlisten,
    };
    const mutations = this.mutationCallbacks;
    const resizes = this.resizeCallbacks;
    class Mutations {
      constructor(private readonly run: (records: unknown[]) => void) {}
      observe() {
        mutations.add(this.run);
      }
      disconnect() {
        mutations.delete(this.run);
      }
    }
    class Resizes {
      constructor(private readonly run: () => void) {}
      observe() {
        resizes.add(this.run);
      }
      unobserve() {}
      disconnect() {
        resizes.delete(this.run);
      }
    }
    class Channel {
      port1: { onmessage: (() => void) | null; close(): void } = { onmessage: null, close: () => undefined };
      port2 = {
        postMessage: () => page.messages.push(() => this.port1.onmessage?.()),
        close: () => undefined,
      };
    }
    this.win = {
      document: doc,
      performance: { now: () => this.now },
      MutationObserver: Mutations,
      ResizeObserver: Resizes,
      MessageChannel: Channel,
      requestAnimationFrame: (run: () => void) => {
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

  private elementOf(row: FakeRow) {
    let element = row.element ?? this.elements.get(row.id);
    if (!element) {
      element = {};
      this.elements.set(row.id, element);
    }
    return Object.assign(element, {
      dataset: { rowId: row.id },
      classList: classes(["acpmux-row", `acpmux-${row.kind ?? "assistant"}`]),
      style: {},
      getBoundingClientRect: () => {
        const now = this.rows.find((one) => one.id === row.id) ?? row;
        return box(now.top, now.height);
      },
    });
  }

  /// The DOM changed: rows mounted (`mounted`) or not.
  mutate(change: () => void, mounted = false): void {
    change();
    const records = mounted
      ? [{ type: "childList", addedNodes: [{ classList: classes(["acpmux-row"]) }], removedNodes: [] }]
      : [{ type: "attributes", addedNodes: [], removedNodes: [] }];
    for (const run of this.mutationCallbacks) run(records);
  }

  resize(change: () => void): void {
    change();
    for (const run of this.resizeCallbacks) run();
  }

  dispatch(type: string, event: object = {}): void {
    for (const one of this.listeners.filter((listener) => listener.type === type))
      one.run({ type, ...event } as unknown as Event);
  }

  /// Runs every timer and frame up to `until` (ms): a frame each 16 ms, its callbacks, then its paint,
  /// then the messages its callbacks posted.
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
      if (next % 16 !== 0) continue;
      const queued = [...this.frameQueue.values()];
      this.frameQueue.clear();
      for (const run of queued) {
        if (this.counting) this.wakeups += 1;
        run();
      }
      for (const run of this.messages.splice(0)) {
        if (this.counting) this.wakeups += 1;
        run();
      }
    }
  }
}

/// Three rows in view, the page's own watch started on them and the first frame read.
function settledPage(): { page: FakePage; watch: LayoutWatcher } {
  const page = new FakePage();
  page.rows = [
    { id: "user-1001", top: 100, height: 120 },
    { id: "assistant-1002", top: 220, height: 200 },
    { id: "user-1003", top: 420, height: 120 },
  ];
  const watch = new LayoutWatcher(page.win);
  watch.start();
  page.advanceTo(200);
  return { page, watch };
}

const shift = (rows: FakeRow[], by: number) => rows.map((row) => ({ ...row, top: row.top + by }));

afterEach(() => resetLayoutWatchForTests());

describe("layout watch: I2, rows in view move only for a reason", () => {
  test("a row mounted above the view that pushes the rows in view down, with no input, is flagged", () => {
    const { page, watch } = settledPage();
    page.mutate(() => {
      page.rows = [{ id: "notice-9000", top: -60, height: 60 }, ...shift(page.rows, 60)];
    }, true);
    page.advanceTo(400);
    const events = watch.unexplained().filter((event) => event.invariant === "I2");
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ invariant: "I2", cause: "mount", deltaPx: 60 });
    expect(events[0]!.rowId).toBe("user-1001");
  });

  test("an append at the bottom that the followed view rides up is not", () => {
    const { page, watch } = settledPage();
    page.mutate(() => {
      page.rows = [...shift(page.rows, -100), { id: "assistant-1004", top: 440, height: 100 }];
    }, true);
    page.advanceTo(400);
    // The streaming bottom row grows and the view follows it.
    page.resize(() => {
      page.rows = shift(page.rows, -40).map((row) =>
        row.id === "assistant-1004" ? { ...row, height: row.height + 40 } : row,
      );
    });
    page.advanceTo(600);
    expect(watch.unexplained()).toEqual([]);
  });

  test("a prepend declared with expect() is not; one that moves its named anchor is", () => {
    const { page, watch } = settledPage();
    const stop = watch.expect("prepend-older", { ms: 300 });
    page.mutate(() => {
      page.rows = [{ id: "user-900", top: 80, height: 120 }, ...shift(page.rows, 100)];
    }, true);
    page.advanceTo(400);
    stop();
    expect(watch.unexplained()).toEqual([]);

    watch.expect("prepend-older", { anchor: "assistant-1002", ms: 300 });
    page.mutate(() => {
      page.rows = [{ id: "user-800", top: -10, height: 120 }, ...shift(page.rows, 30)];
    }, true);
    page.advanceTo(800);
    const events = watch.unexplained();
    expect(events.some((event) => event.invariant === "I2" && event.expect === "prepend-older")).toBe(true);
  });

  test("rows an expect() does not name hold still", () => {
    const { page, watch } = settledPage();
    watch.expect("fold-toggle", { rows: ["user-1003"], ms: 300 });
    page.mutate(() => {
      page.rows = page.rows.map((row) => (row.id === "user-1001" ? { ...row, top: row.top + 20 } : row));
    });
    page.advanceTo(400);
    expect(watch.unexplained()[0]).toMatchObject({ invariant: "I2", rowId: "user-1001", expect: "fold-toggle" });
  });

  test("a scroll by the reader's wheel is not", () => {
    const { page, watch } = settledPage();
    page.dispatch("wheel");
    page.dispatch("scroll");
    page.rows = shift(page.rows, -150);
    page.advanceTo(200 + INPUT_MS - 50);
    expect(watch.unexplained()).toEqual([]);
    // Past the input window the same move is flagged.
    page.advanceTo(200 + INPUT_MS + 100);
    page.dispatch("scroll");
    page.rows = shift(page.rows, -150);
    page.advanceTo(800);
    expect(watch.unexplained().map((event) => event.invariant)).toEqual(["I2"]);
  });
});

describe("layout watch: the other per-frame invariants", () => {
  test("I3: a band over 40 px with no row drawn between rows in view, once while it lasts", () => {
    const { page, watch } = settledPage();
    // A row drawn translucent (an older page fading in) counts as no row.
    const styled = page.win as unknown as {
      getComputedStyle: (element: { dataset: { rowId: string } }) => { opacity: string };
    };
    styled.getComputedStyle = (element) => ({
      opacity: String(page.rows.find((row) => row.id === element.dataset.rowId)?.opacity ?? 1),
    });
    page.mutate(() => {
      page.rows = page.rows.map((row) => (row.id === "assistant-1002" ? { ...row, opacity: 0.5 } : row));
    });
    page.advanceTo(400);
    page.mutate(() => undefined);
    page.advanceTo(600);
    const bands = watch.unexplained().filter((event) => event.invariant === "I3");
    expect(bands).toHaveLength(1);
    expect(bands[0]).toMatchObject({ rowId: "user-1003", deltaPx: 200 });
  });

  test("I5: a row whose height changes on consecutive frames, not the streaming bottom row", () => {
    const { page, watch } = settledPage();
    let steps = 3;
    const grow = () => {
      page.rows = page.rows.map((row) =>
        row.id === "user-1001" || row.id === "user-1003" ? { ...row, height: row.height + 10 } : row,
      );
    };
    for (; steps > 0; steps -= 1) {
      page.resize(grow);
      page.advanceTo(page.now + 16);
    }
    const sized = watch.unexplained().filter((event) => event.invariant === "I5");
    expect(sized.map((event) => event.rowId)).toEqual(["user-1001"]);
  });

  test("I6: one id drawn as another kind, and working-<id> becoming worked-<id> in place", () => {
    const { page, watch } = settledPage();
    page.mutate(() => {
      page.rows = page.rows.map((row) => (row.id === "user-1003" ? { ...row, kind: "notice" } : row));
    }, true);
    page.advanceTo(400);
    page.mutate(() => {
      page.rows = page.rows.map((row) => (row.id === "assistant-1002" ? { ...row, id: "worked-1002" } : row));
    }, true);
    page.advanceTo(600);
    const remade = watch.unexplained().filter((event) => event.invariant === "I6");
    expect(remade.map((event) => event.rowId)).toEqual(["user-1003", "worked-1002"]);
  });
});

describe("layout watch: the settled tick", () => {
  test("ticks once things stop, after an expect() closes; I1 flags a gap over 32 px at rest (under the 40 px band I3 flags)", () => {
    const { page, watch } = settledPage();
    const ticks = watch.settledCount();
    watch.expect("fold-toggle", { ms: 200 });
    page.mutate(() => {
      page.rows = page.rows.map((row) => (row.id === "user-1003" ? { ...row, top: row.top + 36 } : row));
    });
    page.advanceTo(300);
    expect(watch.settledCount()).toBe(ticks);
    page.advanceTo(600);
    expect(watch.settledCount()).toBe(ticks + 1);
    expect(watch.unexplained()).toEqual([
      expect.objectContaining({ invariant: "I1", rowId: "user-1003", selector: "gap", deltaPx: 36 }),
    ]);
  });
});

describe("layout watch at rest", () => {
  test("arms no frame, message or timer once nothing moves (bench idle_wakeups)", () => {
    const { page } = settledPage();
    page.mutate(() => {
      page.rows = [...shift(page.rows, -100), { id: "assistant-1004", top: 440, height: 100 }];
    }, true);
    page.advanceTo(1_000);
    page.counting = true;
    page.advanceTo(6_000);
    expect(page.wakeups).toBe(0);
  });

  test("an expect() with no watch running is a no-op; a perf capture's hold starts and stops it", () => {
    const page = new FakePage();
    expect(layoutWatch.expect("open-at-latest", { ms: 300 })()).toBeUndefined();
    const lease = retainLayoutWatch(page.win);
    page.rows = [{ id: "user-1", top: 100, height: 100 }];
    page.advanceTo(100);
    page.mutate(() => {
      page.rows = [{ id: "notice-77777", top: 100, height: 40 }, ...shift(page.rows, 40)];
    }, true);
    page.advanceTo(300);
    expect(lease.count()).toBe(1);
    lease.release();
    page.counting = true;
    page.mutate(() => undefined);
    page.advanceTo(1_000);
    expect(page.wakeups).toBe(0);
  });
});

describe("layout watch: who runs it", () => {
  test("dev and every non-Release scheme, or a harness that asked", () => {
    const win = {} as Window;
    expect(layoutWatchWanted("cmux", false, win)).toBe(false);
    expect(layoutWatchWanted(undefined, false, win)).toBe(false);
    expect(layoutWatchWanted("cmux-nightly", false, win)).toBe(true);
    expect(layoutWatchWanted("cmux-dev-lane", false, win)).toBe(true);
    expect(layoutWatchWanted("cmux", true, win)).toBe(true);
    expect(layoutWatchWanted("cmux", false, { __cmuxLayoutWatch: true } as unknown as Window)).toBe(true);
  });

  test("window.cmuxLayoutWatch reads the events, and the record sink gets no row id", () => {
    const page = new FakePage();
    const records: object[] = [];
    installLayoutWatch(page.win, {
      wanted: true,
      dev: false,
      record: (event) => records.push({ inv: event.invariant, dy: event.deltaPx }),
    });
    page.rows = [{ id: "user-1", top: 100, height: 100 }];
    page.advanceTo(100);
    page.mutate(() => {
      page.rows = shift(page.rows, 25);
    });
    page.advanceTo(300);
    expect(page.win.cmuxLayoutWatch?.unexplained().map((event) => event.invariant)).toEqual(["I2"]);
    expect(records).toEqual([{ inv: "I2", dy: 25 }]);
  });

  test("id tails and clock values", () => {
    expect(idTail("working-abc-123")).toBe("abc-123");
    expect(idTail("lane-notices:n42")).toBe("n42");
    expect(clockSeconds("1m 05s")).toBe(65);
    expect(clockSeconds("2h")).toBe(7200);
    expect(clockSeconds("now")).toBeUndefined();
  });
});
