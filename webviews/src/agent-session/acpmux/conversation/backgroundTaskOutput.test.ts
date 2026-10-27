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

/** How the registry row reads once the process ends: its state, and the fields the harness reported. */
type EndedRow = { state: "exited" | "failed" | "killed" | "lost" } & Record<string, unknown>;

/** A registry with one Claude Code shell; `exit` or `end` ends it. Counts the reads. */
function fakeReader(): {
  reader: BackgroundTaskOutputReader;
  reads: () => number;
  exit(code: number): void;
  end(row: EndedRow): void;
} {
  let lists = 0;
  let ended: EndedRow | undefined;
  const data = btoa("building\n");
  return {
    reader: {
      sessionId: "s1",
      source: {
        listProcesses: async () => {
          lists += 1;
          return {
            processes: [{ id: "p1", toolCallId: "t1", harness: "claude", ...(ended ?? { state: "running" }) }],
          };
        },
        tailProcess: async () => ({ data, fromByte: 0 }),
      },
    },
    reads: () => lists,
    exit(code) {
      ended = { state: "exited", exitCode: code };
    },
    end(row) {
      ended = row;
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
    expect(seen.at(-1)).toEqual({ exitCode: 0, ended: true, output: "building\n", cut: false });
    expect(timers.live).toBe(0);
    timers.advance(BACKGROUND_TAIL_POLL_MS * 5);
    await settle();
    expect(reads()).toBe(2);
  });

  // acpmux's registry gives a lost process no exit code (processes.rs fold and lose_running), and a
  // killed or failed one only when the harness reported it; its output is final all the same.
  for (const [name, row] of [
    ["lost", { state: "lost" }],
    ["killed by a signal", { state: "killed", signal: "SIGTERM" }],
    ["failed", { state: "failed" }],
  ] as const) {
    test(`the poll ends once the registry reports the process ${name}, with no exit code`, async () => {
      const doc = new FakeDocument();
      const timers = new FakeTimers();
      const { reader, reads, end } = fakeReader();
      const seen: BackgroundTaskOutput[] = [];
      pollBackgroundTaskOutput(reader, "t1", undefined, (output) => seen.push(output), {
        lifecycle: new PageLifecycle(doc),
        timers,
      });
      await settle();
      expect(timers.live).toBe(1);
      end(row);
      timers.advance(BACKGROUND_TAIL_POLL_MS);
      await settle();
      expect(seen.at(-1)).toEqual({ ended: true, output: "building\n", cut: false });
      expect(timers.live).toBe(0);
      timers.advance(BACKGROUND_TAIL_POLL_MS * 5);
      await settle();
      expect(reads()).toBe(2);
    });
  }

  test("a process the registry does not list yet keeps the poll going", async () => {
    const doc = new FakeDocument();
    const timers = new FakeTimers();
    let lists = 0;
    const reader: BackgroundTaskOutputReader = {
      sessionId: "s1",
      source: {
        listProcesses: async () => {
          lists += 1;
          return { processes: [] };
        },
        tailProcess: async () => ({}),
      },
    };
    const seen: BackgroundTaskOutput[] = [];
    const stop = pollBackgroundTaskOutput(reader, "t1", undefined, (output) => seen.push(output), {
      lifecycle: new PageLifecycle(doc),
      timers,
    });
    await settle();
    expect(seen).toEqual([{}]);
    expect(timers.live).toBe(1);
    timers.advance(BACKGROUND_TAIL_POLL_MS);
    await settle();
    expect(lists).toBe(2);
    expect(timers.live).toBe(1);
    stop();
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
