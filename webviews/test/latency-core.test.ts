import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { measureOnce, type LatencyAction } from "./latency/measure";
import { installLatencyProbe } from "./latency/probe";

function harness() {
  const dom = new JSDOM("<!doctype html><output></output>", { runScripts: "outside-only" });
  const w = dom.window;
  const frames = new Map<number, FrameRequestCallback>();
  const observers = new Set<object>();
  const tasks: Array<() => void> = [];
  const records: PerformanceEntry[] = [];
  let serial = 0;
  let now = 100;
  Object.defineProperty(w.performance, "now", { value: () => now });
  w.requestAnimationFrame = (fn) => (frames.set(++serial, fn), serial);
  w.cancelAnimationFrame = (id) => {
    frames.delete(id);
  };
  const Mutation = w.MutationObserver;
  w.MutationObserver = class extends Mutation {
    observe(target: Node, options?: MutationObserverInit) {
      observers.add(this);
      super.observe(target, options);
    }
    disconnect() {
      observers.delete(this);
      super.disconnect();
    }
  };
  w.MessageChannel = class {
    closed = false;
    port1 = {
      onmessage: null as (() => void) | null,
      close: () => {
        this.closed = true;
      },
    };
    port2 = {
      postMessage: () =>
        tasks.push(() => {
          if (!this.closed) this.port1.onmessage?.();
        }),
      close: () => {
        this.closed = true;
      },
    };
  } as unknown as typeof MessageChannel;
  w.PerformanceObserver = class {
    static supportedEntryTypes = ["longtask", "event"];
    type = "";
    observe(options: { type: string }) {
      this.type = options.type;
      observers.add(this);
    }
    disconnect() {
      observers.delete(this);
    }
    takeRecords() {
      return records.filter((entry) => entry.entryType === this.type);
    }
  } as unknown as typeof PerformanceObserver;
  w.eval(`(${installLatencyProbe.toString()})();`);
  const probe = w.__latency! as NonNullable<Window["__latency"]> & { stop(): void; dispose(): void };
  return {
    w,
    probe,
    frames,
    observers,
    records,
    advance(ms: number) {
      now += ms;
    },
    flushTasks() {
      while (tasks.length) tasks.shift()!();
    },
    frame() {
      now += 16.7;
      const pending = [...frames.values()];
      frames.clear();
      for (const fn of pending) fn(now);
    },
    close() {
      dom.window.close();
    },
  };
}

test("an installed probe does no recurring work before an action", () => {
  const h = harness();
  try {
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
  } finally {
    h.close();
  }
});

test("post-response frame work and queued Long Tasks entries survive until finalization", () => {
  const h = harness();
  try {
    let visible = false;
    h.w.__latencyCheck = () => visible;
    h.probe.arm("response");
    const input = new h.w.Event("keydown");
    Object.defineProperty(input, "timeStamp", { value: 100 });
    h.w.dispatchEvent(input);
    visible = true;
    h.frame();
    expect(h.probe.state).toBe("input");
    h.advance(80);
    h.records.push({ entryType: "longtask", startTime: 116.7, duration: 80 } as PerformanceEntry);
    h.flushTasks();
    expect(h.probe.result()?.paint).toBeCloseTo(96.7);
    expect(h.probe.result()?.maxFrameGap).toBeCloseTo(96.7);
    expect(h.probe.result()?.longTasks).toEqual([80]);
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
  } finally {
    h.close();
  }
});

test("stop and disposal cancel an armed window and allow clean rearming", () => {
  const h = harness();
  try {
    h.w.__latencyCheck = () => false;
    h.probe.arm("false");
    expect(h.frames.size).toBe(1);
    expect(h.observers.size).toBeGreaterThan(0);
    h.probe.stop();
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
    h.probe.arm("false");
    h.probe.dispose();
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
    expect(h.w.__latency).toBeUndefined();
  } finally {
    h.close();
  }
});

test("input failures stop measurement before settle runs", async () => {
  const h = harness();
  h.w.__latencyCheck = () => false;
  const page = {
    evaluate: async (fn: unknown, arg?: unknown) => {
      if (typeof fn === "string") return h.w.eval(fn);
      return h.w.eval(`(${String(fn)})(${JSON.stringify(arg) ?? "undefined"})`);
    },
  } as unknown as Parameters<typeof measureOnce>[0];
  const action: LatencyAction = {
    name: "broken input",
    prepare: async () => "false",
    input: async () => {
      throw new Error("input unavailable");
    },
    settle: async () => {
      expect(h.frames.size).toBe(0);
      expect(h.observers.size).toBe(0);
    },
  };
  try {
    const result = await measureOnce(page, action);
    expect(result.error).toContain("input unavailable");
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
  } finally {
    h.close();
  }
});

test("completion records real commits and leaves no frame or observer running", () => {
  const h = harness();
  try {
    h.w.__latencyCheck = () => Boolean(h.w.document.querySelector("output")!.textContent);
    h.w.__latencyReactCommits = 10;
    h.probe.arm("visible output");
    h.probe.markInput("host-command");
    h.w.document.querySelector("output")!.textContent = "ready";
    h.w.__latencyReactCommits += 2;
    h.frame();
    h.flushTasks();
    expect(h.probe.state).toBe("done");
    expect(h.probe.result()?.reactCommits).toBe(2);
    expect(h.frames.size).toBe(0);
    expect(h.observers.size).toBe(0);
  } finally {
    h.close();
  }
});
