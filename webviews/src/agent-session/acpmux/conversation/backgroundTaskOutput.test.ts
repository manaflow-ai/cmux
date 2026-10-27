// An expanded tray row reads its running task's tail only while the page is shown (p14-energy-110):
// a hidden or frozen page arms no timer, showing it again reads nothing until the next period, and
// the poll ends once the registry reports the process's exit.
import { describe, expect, test } from "bun:test";
import { type LifecycleDocument, PageLifecycle, type PageTimers } from "../../../pages/shared/pageLifecycle";
import {
  BACKGROUND_TAIL_POLL_MS,
  type BackgroundTaskOutput,
  type BackgroundTaskOutputReader,
  pollBackgroundTaskOutput,
} from "./backgroundTaskOutput";

class FakeDocument implements LifecycleDocument {
  visibilityState = "visible";
  private readonly listeners = new Map<string, Set<() => void>>();

  addEventListener(type: string, listener: () => void): void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: () => void): void {
    this.listeners.get(type)?.delete(listener);
  }

  set(state: "visible" | "hidden"): void {
    this.visibilityState = state;
    for (const listener of this.listeners.get("visibilitychange") ?? []) listener();
  }
}

/** Intervals run only when the test advances the clock. */
class FakeTimers implements PageTimers {
  private next = 1;
  private now = 0;
  private readonly intervals = new Map<number, { ms: number; callback: () => void; due: number }>();

  every(ms: number, callback: () => void): unknown {
    const id = this.next++;
    this.intervals.set(id, { ms, callback, due: this.now + ms });
    return id;
  }

  cancelEvery(handle: unknown): void {
    this.intervals.delete(handle as number);
  }

  frame(): unknown {
    throw new Error("the tail poll asks for no frame");
  }

  cancelFrame(): void {}

  get live(): number {
    return this.intervals.size;
  }

  advance(ms: number): void {
    const end = this.now + ms;
    for (;;) {
      let soonest: { ms: number; callback: () => void; due: number } | undefined;
      for (const interval of this.intervals.values())
        if (interval.due <= end && (!soonest || interval.due < soonest.due)) soonest = interval;
      if (!soonest) break;
      this.now = soonest.due;
      soonest.due += soonest.ms;
      soonest.callback();
    }
    this.now = end;
  }
}

/** A registry with one Claude Code shell; `exit` ends it. Counts the reads. */
function fakeReader(): { reader: BackgroundTaskOutputReader; reads: () => number; exit(code: number): void } {
  let lists = 0;
  let exitCode: number | undefined;
  const data = btoa("building\n");
  return {
    reader: {
      sessionId: "s1",
      source: {
        listProcesses: async () => {
          lists += 1;
          return {
            processes: [
              {
                id: "p1",
                toolCallId: "t1",
                harness: "claude",
                state: exitCode === undefined ? "running" : "exited",
                ...(exitCode === undefined ? {} : { exitCode }),
              },
            ],
          };
        },
        tailProcess: async () => ({ data, fromByte: 0 }),
      },
    },
    reads: () => lists,
    exit(code) {
      exitCode = code;
    },
  };
}

/** Lets the read's promise chain (list, then tail, then the answer) settle. */
async function settle(): Promise<void> {
  for (let index = 0; index < 5; index += 1) await Promise.resolve();
}

describe("pollBackgroundTaskOutput", () => {
  test("reads at once and every period while the page is shown", async () => {
    const doc = new FakeDocument();
    const timers = new FakeTimers();
    const { reader, reads } = fakeReader();
    const seen: BackgroundTaskOutput[] = [];
    const stop = pollBackgroundTaskOutput(reader, "t1", undefined, (output) => seen.push(output), {
      lifecycle: new PageLifecycle(doc),
      timers,
    });
    await settle();
    expect(reads()).toBe(1);
    expect(seen.at(-1)).toEqual({ running: true, output: "building\n", cut: false });
    timers.advance(BACKGROUND_TAIL_POLL_MS);
    await settle();
    expect(reads()).toBe(2);
    stop();
    expect(timers.live).toBe(0);
  });

  test("a hidden page arms no timer and reads nothing, and showing it waits for the next period", async () => {
    const doc = new FakeDocument();
    const timers = new FakeTimers();
    const { reader, reads } = fakeReader();
    pollBackgroundTaskOutput(reader, "t1", undefined, () => {}, { lifecycle: new PageLifecycle(doc), timers });
    await settle();
    expect(reads()).toBe(1);

    doc.set("hidden");
    expect(timers.live).toBe(0);
    timers.advance(BACKGROUND_TAIL_POLL_MS * 10);
    await settle();
    expect(reads()).toBe(1);

    doc.set("visible");
    await settle();
    expect(reads()).toBe(1);
    expect(timers.live).toBe(1);
    timers.advance(BACKGROUND_TAIL_POLL_MS);
    await settle();
    expect(reads()).toBe(2);
  });

  test("a row opened while the page is hidden reads nothing until the page shows", async () => {
    const doc = new FakeDocument();
    doc.set("hidden");
    const timers = new FakeTimers();
    const { reader, reads } = fakeReader();
    pollBackgroundTaskOutput(reader, undefined, "p1", () => {}, { lifecycle: new PageLifecycle(doc), timers });
    await settle();
    expect(reads()).toBe(0);
    expect(timers.live).toBe(0);
  });

  test("the poll ends once the registry reports the exit", async () => {
    const doc = new FakeDocument();
    const timers = new FakeTimers();
    const { reader, reads, exit } = fakeReader();
    const seen: BackgroundTaskOutput[] = [];
    pollBackgroundTaskOutput(reader, "t1", undefined, (output) => seen.push(output), {
      lifecycle: new PageLifecycle(doc),
      timers,
    });
    await settle();
    exit(0);
    timers.advance(BACKGROUND_TAIL_POLL_MS);
    await settle();
    expect(seen.at(-1)).toEqual({ exitCode: 0, output: "building\n", cut: false });
    expect(timers.live).toBe(0);
    timers.advance(BACKGROUND_TAIL_POLL_MS * 5);
    await settle();
    expect(reads()).toBe(2);
  });

  test("nothing reaches the row after the stop", async () => {
    const doc = new FakeDocument();
    const timers = new FakeTimers();
    const { reader } = fakeReader();
    const seen: BackgroundTaskOutput[] = [];
    const stop = pollBackgroundTaskOutput(reader, "t1", undefined, (output) => seen.push(output), {
      lifecycle: new PageLifecycle(doc),
      timers,
    });
    stop();
    await settle();
    expect(seen).toEqual([]);
    expect(timers.live).toBe(0);
  });
});
