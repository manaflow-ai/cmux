import { describe, expect, test } from "bun:test";
import {
  BUSY_PREFIX,
  BUSY_REPEAT_MS,
  BUSY_WINDOW_MS,
  BusyWatchdog,
  installBusyWatchdog,
  scriptSite,
  type LongFrameEntry,
} from "./busyWatchdog";

/// Long frames of `ms` each, back to back from `from`, for `span` ms: a page `ms / gap` busy.
function frames(from: number, span: number, ms: number, gap: number, scripts?: LongFrameEntry["scripts"]) {
  const out: LongFrameEntry[] = [];
  for (let at = from; at < from + span; at += gap)
    out.push({ startTime: at, duration: ms, styleAndLayoutStart: at + ms * 0.75, scripts });
  return out;
}

/// The first long frame after `at`: it ends the window before it.
const after = (at: number): LongFrameEntry[] => [{ startTime: at, duration: 1 }];

const rerender = [
  {
    invoker: "FrameRequestCallback",
    sourceURL: "cmux-page://cmux.agent/chunks/chunk-ABC.js?v=1",
    sourceFunctionName: "flushRows",
    sourceCharPosition: 4321,
    duration: 60,
  },
];

describe("BusyWatchdog", () => {
  test("names the hot script once a page stays busy for 30 s", () => {
    const reports: string[] = [];
    const dog = new BusyWatchdog(
      (message) => reports.push(message),
      () => "page hidden, 900 elements",
    );
    // 80 ms long frames every 100 ms: 80% busy, the shape of the renderer stuck at 115% CPU.
    dog.add(frames(0, 2 * BUSY_WINDOW_MS, 80, 100, rerender));
    expect(reports).toHaveLength(0);
    dog.add(frames(2 * BUSY_WINDOW_MS, BUSY_WINDOW_MS, 80, 100, rerender));
    // A window counts once it is over: the next long frame closes the third one.
    expect(reports).toHaveLength(0);
    dog.add(after(3 * BUSY_WINDOW_MS));
    expect(reports).toHaveLength(1);
    const line = reports[0]!;
    expect(line.startsWith(BUSY_PREFIX)).toBe(true);
    expect(line).toContain("80% busy in long frames for 30 s");
    expect(line).toContain("25% style and layout");
    expect(line).toContain("page hidden, 900 elements");
    expect(line).toContain("FrameRequestCallback > flushRows@chunk-ABC.js:4321");
    // One line: the console capture keeps only the first line of a report.
    expect(line).not.toContain("\n");
    expect(line.length).toBeLessThan(1024);
  });

  test("says nothing for a page that is busy in short bursts", () => {
    const reports: string[] = [];
    const dog = new BusyWatchdog((message) => reports.push(message));
    // 30% busy: a streaming chat drawing its replies, not a stuck page.
    dog.add(frames(0, 10 * BUSY_WINDOW_MS, 60, 200, rerender));
    // Busy, then a quiet window, then busy again: never three busy windows in a row.
    dog.add(frames(10 * BUSY_WINDOW_MS, 2 * BUSY_WINDOW_MS, 80, 100, rerender));
    dog.add(frames(13 * BUSY_WINDOW_MS, 2 * BUSY_WINDOW_MS, 80, 100, rerender));
    expect(reports).toHaveLength(0);
  });

  test("repeats at most every five minutes while the page stays busy", () => {
    const reports: string[] = [];
    const dog = new BusyWatchdog((message) => reports.push(message));
    dog.add(frames(0, BUSY_REPEAT_MS + 4 * BUSY_WINDOW_MS, 80, 100, rerender));
    expect(reports).toHaveLength(2);
  });

  test("a frame with no attributed script still counts and says so", () => {
    const reports: string[] = [];
    const dog = new BusyWatchdog((message) => reports.push(message));
    dog.add([...frames(0, 3 * BUSY_WINDOW_MS, 90, 100), ...after(3 * BUSY_WINDOW_MS)]);
    expect(reports[0]).toContain("top scripts: none named");
  });
});

describe("scriptSite", () => {
  test("keeps the file name and position, not the path or query", () => {
    expect(
      scriptSite({
        invokerType: "event-listener",
        sourceURL: "cmux-page://cmux.agent/pane.js#x",
        sourceCharPosition: 12,
        duration: 1,
      }),
    ).toBe("event-listener > (anonymous)@pane.js:12");
    expect(scriptSite({ duration: 1, sourceCharPosition: -1 })).toBe("? > (anonymous)@?");
  });
});

describe("installBusyWatchdog", () => {
  test("installs nothing on an engine without long-animation-frame entries", () => {
    const win = {
      PerformanceObserver: { supportedEntryTypes: ["mark", "measure"] },
      document: {},
      console,
    } as unknown as Window & typeof globalThis;
    expect(installBusyWatchdog(win)).toBe(false);
  });

  test("observes long-animation-frame entries and reports through console.error", () => {
    const errors: string[] = [];
    let deliver: ((list: { getEntries(): unknown[] }) => void) | undefined;
    let observed: unknown;
    class FakeObserver {
      static supportedEntryTypes = ["long-animation-frame"];
      constructor(callback: (list: { getEntries(): unknown[] }) => void) {
        deliver = callback;
      }
      observe(options: unknown) {
        observed = options;
      }
    }
    const win = {
      PerformanceObserver: FakeObserver,
      document: { visibilityState: "visible", getElementsByTagName: () => ({ length: 42 }) },
      console: { error: (message: string) => errors.push(message) },
    } as unknown as Window & typeof globalThis;
    expect(installBusyWatchdog(win)).toBe(true);
    expect(observed).toEqual({ type: "long-animation-frame", buffered: true });
    const entries = [...frames(0, 3 * BUSY_WINDOW_MS, 80, 100, rerender), ...after(3 * BUSY_WINDOW_MS)];
    deliver!({ getEntries: () => entries });
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("page visible, 42 elements");
  });
});
