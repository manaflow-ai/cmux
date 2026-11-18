import { afterEach, expect, test } from "bun:test";
import { AcpmuxPerf, typingSummary } from "./perf";

// The composer key listener (AcpmuxPerf.enable) on a fake page: a key's `to_work` ends at the first point after the
// key's task, the message its edit posts or the next frame, whichever runs first (goal typing-latency).

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let now = 0;
let frames: (() => void)[] = [];
let messages: (() => void)[] = [];

class TestChannel {
  port1: { onmessage: (() => void) | null; close: () => void } = { onmessage: null, close: () => {} };
  port2 = { postMessage: () => messages.push(() => this.port1.onmessage?.()) };
}

function install() {
  for (const key of ["requestAnimationFrame", "MessageChannel", "performance"]) saved.set(key, scope[key]);
  now = 0;
  frames = [];
  messages = [];
  Object.assign(scope, {
    requestAnimationFrame: (callback: () => void) => frames.push(callback),
    MessageChannel: TestChannel,
    performance: { now: () => now },
  });
}

afterEach(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function page() {
  const listeners = new Map<string, Set<(event: unknown) => void>>();
  return {
    addEventListener: (type: string, listener: (event: unknown) => void) => {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(listener);
    },
    removeEventListener: (type: string, listener: (event: unknown) => void) => listeners.get(type)?.delete(listener),
    fire: (type: string, event: unknown = {}) => {
      // A copy: a listener may remove itself as it runs.
      for (const listener of Array.from(listeners.get(type) ?? [])) listener(event);
    },
  };
}

const composerKey = (timeStamp: number) => ({ timeStamp, target: { closest: () => ({}) } });
const run = (queue: (() => void)[]) => queue.splice(0).forEach((callback) => callback());

test("a frame due before the edit's message ends the key's work at the frame, not after its rendering", () => {
  install();
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  now = 1;
  target.fire("keydown", composerKey(0));
  now = 4;
  target.fire("input");
  now = 5; // the key's task ends; the frame was due, so it runs before the posted message
  run(frames);
  now = 11; // the frame's style, layout and paint took 6 ms
  run(messages);
  expect(perf.typing).toHaveLength(1);
  expect(perf.typing[0]!.work).toBe(5);
  expect(perf.typing[0]!.frame).toBe(5);
  expect(typingSummary(perf.typing).to_work.p95_ms).toBe(5);
});

test("an edit's message that runs before the frame ends the key's work, and the frame does not move it", () => {
  install();
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  target.fire("keydown", composerKey(0));
  now = 3;
  target.fire("input");
  now = 4;
  run(messages);
  now = 9;
  run(frames);
  run(messages);
  expect(perf.typing[0]!.work).toBe(4);
  expect(perf.typing[0]!.frame).toBe(9);
});

test("a key that edits nothing has no work sample, even when its frame runs", () => {
  install();
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  target.fire("keydown", composerKey(0));
  now = 7;
  run(frames);
  run(messages);
  expect(perf.typing[0]!.work).toBeUndefined();
});
