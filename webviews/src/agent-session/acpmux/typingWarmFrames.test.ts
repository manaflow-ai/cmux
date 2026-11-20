import { describe, expect, test } from "bun:test";
import { installTypingWarmFrames, type TypingWarmFramesHost } from "./typingWarmFrames";

type Listener = (event: Event) => void;

function harness(visibility: DocumentVisibilityState = "visible") {
  const listeners = new Map<string, Set<Listener>>();
  const host: TypingWarmFramesHost & { visibilityState: DocumentVisibilityState } = {
    visibilityState: visibility,
    addEventListener: (type, listener) => {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(listener);
    },
    removeEventListener: (type, listener) => {
      listeners.get(type)?.delete(listener);
    },
  };
  let clock = 0;
  const queued: (() => void)[] = [];
  const warm = installTypingWarmFrames(host, {
    holdMs: 100,
    now: () => clock,
    requestFrame: (callback) => queued.push(callback),
  });
  const target = (inComposer: boolean) => ({ closest: (selector: string) => (inComposer ? selector : null) });
  const fire = (type: string, inComposer = true) => {
    for (const listener of listeners.get(type) ?? []) listener({ target: target(inComposer) } as unknown as Event);
  };
  /** Runs one display frame: every callback asked for so far, 8 ms on. */
  const frame = () => {
    clock += 8;
    for (const callback of queued.splice(0)) callback();
  };
  return { host, warm, fire, frame, queued, listeners, advance: (ms: number) => (clock += ms) };
}

describe("typing warm frames", () => {
  test("a composer key starts one frame loop that stops holdMs after the last key", () => {
    const h = harness();
    h.fire("keydown");
    expect(h.warm.running).toBe(true);
    h.fire("keydown");
    expect(h.queued.length).toBe(1);
    for (let i = 0; i < 10; i++) h.frame();
    expect(h.warm.running).toBe(true);
    h.fire("keydown");
    for (let i = 0; i < 20; i++) h.frame();
    expect(h.warm.running).toBe(false);
    expect(h.queued.length).toBe(0);
    const ran = h.warm.frames;
    h.frame();
    expect(h.warm.frames).toBe(ran);
  });

  test("focus in a composer warms too; keys elsewhere do not", () => {
    const h = harness();
    h.fire("keydown", false);
    h.fire("focusin", false);
    expect(h.warm.running).toBe(false);
    h.fire("focusin");
    expect(h.warm.running).toBe(true);
  });

  test("a hidden page stops the loop at its next frame", () => {
    const h = harness();
    h.fire("keydown");
    h.host.visibilityState = "hidden";
    h.frame();
    expect(h.warm.running).toBe(false);
    expect(h.queued.length).toBe(0);
  });

  test("dispose removes the listeners and ends the loop", () => {
    const h = harness();
    h.fire("keydown");
    h.warm.dispose();
    h.frame();
    expect(h.warm.running).toBe(false);
    expect(h.listeners.get("keydown")?.size).toBe(0);
    expect(h.listeners.get("focusin")?.size).toBe(0);
  });
});
