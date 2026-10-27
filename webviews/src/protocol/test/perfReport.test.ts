// The theme bootstrap's field data (WebTheme.bootstrapScript, p09-observability-114), run against a fake
// page: PerformanceObserver entries and window events in, the reports it posts to the host out.
import { describe, expect, test } from "bun:test";
import { runInThisContext } from "node:vm";
import { readWebThemeBootstrap } from "../../../dev-server/galleryHost";
import {
  parsePerfReport,
  PERF_ERROR_REPORT_INTERVAL_MS,
  PERF_EVENT_THRESHOLD_MS,
  PERF_REPORT_CAPACITY,
  PERF_REPORT_HANDLER,
  PERF_SEEN_INTERACTIONS,
  type PerfReport,
} from "../perfReport";

type Listener = (event: unknown) => void;
type Entry = { duration: number; interactionId?: number };

class Events {
  private readonly listeners = new Map<string, Listener[]>();
  addEventListener(type: string, listener: Listener): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  dispatch(type: string, event: unknown = {}): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}

/** A page with the bootstrap run in it: `entries` feeds an observed entry type, `posted` is what reached the host. */
function page(supported: string[]) {
  const posted: unknown[] = [];
  const observers = new Map<string, { take: (list: { getEntries(): Entry[] }) => void; options: unknown }>();
  class FakeObserver {
    static supportedEntryTypes = supported;
    constructor(private readonly take: (list: { getEntries(): Entry[] }) => void) {}
    observe(options: { type: string }): void {
      observers.set(options.type, { take: this.take, options });
    }
  }
  const clock = { now: 0 };
  const window = Object.assign(new Events(), {
    PerformanceObserver: FakeObserver,
    performance: { now: () => clock.now },
    webkit: { messageHandlers: { [PERF_REPORT_HANDLER]: { postMessage: (body: unknown) => posted.push(body) } } },
  });
  const document = Object.assign(new Events(), { documentElement: null, visibilityState: "visible" });
  const script = readWebThemeBootstrap();
  // The page's globals are the fakes: the script runs with them as its parameters.
  const run = runInThisContext(`(function (window, document, PerformanceObserver) {\n${script}\n})`) as (
    ...globals: unknown[]
  ) => void;
  run(window, document, FakeObserver);
  return {
    posted,
    observers,
    clock,
    window,
    document,
    entries(type: string, list: Entry[]) {
      observers.get(type)?.take({ getEntries: () => list });
    },
    reports(): PerfReport[] {
      return posted.map((body) => {
        const report = parsePerfReport(body);
        if (!report) throw new Error(`not a report: ${JSON.stringify(body)}`);
        return report;
      });
    },
  };
}

describe("theme bootstrap field data", () => {
  test("adds no timer", () => {
    const script = readWebThemeBootstrap();
    expect(script).not.toMatch(/setTimeout|setInterval|requestIdleCallback/);
  });

  test("an interaction is its longest entry, and a slow one reports at once", () => {
    const p = page(["event", "long-animation-frame"]);
    expect(p.observers.get("event")?.options).toEqual({
      type: "event",
      buffered: true,
      durationThreshold: PERF_EVENT_THRESHOLD_MS,
    });
    p.entries("event", [
      { duration: 40, interactionId: 7 },
      { duration: 64, interactionId: 7 },
      { duration: 90, interactionId: 0 }, // not an interaction (a hover): no sample
    ]);
    expect(p.posted).toEqual([]);
    p.entries("event", [{ duration: 248, interactionId: 8 }]);
    expect(p.reports()).toEqual([{ v: 1, inp: [64, 248], loaf: [], errors: 0 }]);
  });

  test("an interaction whose entries straddle a slow report is one sample", () => {
    const p = page(["event"]);
    p.entries("event", [{ duration: 260, interactionId: 5 }]);
    p.entries("event", [{ duration: 40, interactionId: 5 }]); // the keyup of the same key press
    p.entries("event", [{ duration: 300, interactionId: 5 }]); // longer, but its sample is already poor
    p.window.dispatch("pagehide");
    expect(p.reports()).toEqual([{ v: 1, inp: [260], loaf: [], errors: 0 }]);
  });

  test("the interactions it recognizes across reports are bounded", () => {
    const p = page(["event"]);
    const ids = Array.from({ length: PERF_SEEN_INTERACTIONS + 1 }, (_, i) => i + 1);
    for (const id of ids) p.entries("event", [{ duration: 20, interactionId: id }]);
    p.window.dispatch("pagehide");
    const counted = p.reports().reduce((sum, report) => sum + report.inp.length, 0);
    expect(counted).toBe(ids.length);
    p.entries("event", [{ duration: 30, interactionId: ids.at(-1)! }]); // recent: still one sample
    p.entries("event", [{ duration: 30, interactionId: 1 }]); // forgotten: counts as new
    p.window.dispatch("pagehide");
    expect(p.reports().at(-1)).toEqual({ v: 1, inp: [30], loaf: [], errors: 0 });
  });

  test("long frames report when the page hides and when it ends", () => {
    const p = page(["event", "long-animation-frame", "longtask"]);
    expect(p.observers.has("longtask")).toBe(false);
    p.entries("long-animation-frame", [{ duration: 80.4 }, { duration: 120.6 }]);
    p.document.dispatch("visibilitychange"); // still visible: no report
    expect(p.posted).toEqual([]);
    p.document.visibilityState = "hidden";
    p.document.dispatch("visibilitychange");
    expect(p.reports()).toEqual([{ v: 1, inp: [], loaf: [80, 121], errors: 0 }]);
    p.window.dispatch("pagehide"); // nothing new: no empty report
    expect(p.posted.length).toBe(1);
  });

  test("a script error reports at once, and a storm at most once an interval", () => {
    const p = page(["long-animation-frame"]);
    p.entries("long-animation-frame", [{ duration: 70 }]);
    p.window.dispatch("error");
    expect(p.reports()).toEqual([{ v: 1, inp: [], loaf: [70], errors: 1 }]);
    p.clock.now = PERF_ERROR_REPORT_INTERVAL_MS - 1;
    p.window.dispatch("unhandledrejection");
    p.window.dispatch("error");
    expect(p.posted.length).toBe(1);
    p.clock.now = PERF_ERROR_REPORT_INTERVAL_MS;
    p.window.dispatch("error");
    expect(p.reports().at(-1)).toEqual({ v: 1, inp: [], loaf: [], errors: 3 });
    p.clock.now += 10;
    p.window.dispatch("error");
    p.window.dispatch("pagehide");
    expect(p.reports().at(-1)).toEqual({ v: 1, inp: [], loaf: [], errors: 1 });
  });

  test("WebKit without long animation frames observes long tasks", () => {
    const p = page(["longtask"]);
    expect(p.observers.has("event")).toBe(false);
    p.entries("longtask", [{ duration: 70 }]);
    p.window.dispatch("pagehide");
    expect(p.reports()).toEqual([{ v: 1, inp: [], loaf: [70], errors: 0 }]);
  });

  test("a full list reports in the batch that filled it", () => {
    const p = page(["long-animation-frame"]);
    const frames = Array.from({ length: PERF_REPORT_CAPACITY + 3 }, (_, i) => ({ duration: 51 + i }));
    p.entries("long-animation-frame", frames);
    const [first] = p.reports();
    expect(first?.loaf.length).toBe(PERF_REPORT_CAPACITY);
    p.window.dispatch("pagehide");
    expect(p.reports()[1]?.loaf).toEqual([83, 84, 85]);
  });

  test("a page without the host handler (the gallery) posts nothing and throws nothing", () => {
    const p = page(["long-animation-frame"]);
    delete (p.window as { webkit?: unknown }).webkit;
    p.entries("long-animation-frame", [{ duration: 60 }]);
    expect(() => p.window.dispatch("pagehide")).not.toThrow();
    expect(p.posted).toEqual([]);
  });
});

describe("parsePerfReport", () => {
  test("takes a report", () => {
    expect(parsePerfReport({ v: 1, inp: [20.4], loaf: [], errors: 0 })).toEqual({
      v: 1,
      inp: [20],
      loaf: [],
      errors: 0,
    });
  });

  test("refuses a planted URL or page name", () => {
    expect(parsePerfReport({ v: 1, inp: [], loaf: [], errors: 0, url: "https://example.com/" })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: [], loaf: [], errors: 0, page: "settings" })).toBeNull();
  });

  test("refuses other versions, shapes and numbers", () => {
    expect(parsePerfReport({ v: 2, inp: [], loaf: [], errors: 0 })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: ["20"], loaf: [], errors: 0 })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: [-1], loaf: [], errors: 0 })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: [], loaf: [Number.NaN], errors: 0 })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: [], loaf: [], errors: 1.5 })).toBeNull();
    expect(parsePerfReport({ v: 1, inp: Array.from({ length: 65 }, () => 20), loaf: [], errors: 0 })).toBeNull();
    expect(parsePerfReport([1])).toBeNull();
    expect(parsePerfReport(null)).toBeNull();
  });
});
