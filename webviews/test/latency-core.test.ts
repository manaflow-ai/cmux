import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { measureOnce, type LatencyAction } from "./latency/measure";
import { installLatencyProbe } from "./latency/probe";

function harness() {
  const dom = new JSDOM("<!doctype html><output></output>", { runScripts: "outside-only" });
  const w = dom.window;
  const frames = new Map<number, FrameRequestCallback>();
  const observers = new Set<object>();
  let serial = 0;
  let now = 100;
  Object.defineProperty(w.performance, "now", { value: () => now });
  w.requestAnimationFrame = (fn) => (frames.set(++serial, fn), serial);
  w.cancelAnimationFrame = (id) => {
    frames.delete(id);
  };
  w.PerformanceObserver = class {
    static supportedEntryTypes = ["longtask", "event"];
    observe() {
      observers.add(this);
    }
    disconnect() {
      observers.delete(this);
    }
    takeRecords() {
      return [];
    }
  } as unknown as typeof PerformanceObserver;
  w.eval(`(${installLatencyProbe.toString()})();`);
  const probe = w.__latency! as NonNullable<Window["__latency"]> & { stop(): void; dispose(): void };
  return {
    w,
    probe,
    frames,
    observers,
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
