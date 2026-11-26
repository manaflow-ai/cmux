import { afterEach, expect, test } from "bun:test";
import { AcpmuxPerf, typingSummary } from "./perf";

// The composer key listener (AcpmuxPerf.enable) on a fake page: a key's `to_work` ends inside the key's own task, in a
// microtask after its `input` event reaches the document, whenever its frame runs (goal typing-latency).

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let now = 0;
let frames: (() => void)[] = [];
let messages: (() => void)[] = [];
let microtasks: (() => void)[] = [];

class TestChannel {
  port1: { onmessage: (() => void) | null; close: () => void } = { onmessage: null, close: () => {} };
  port2 = { postMessage: () => messages.push(() => this.port1.onmessage?.()) };
}

function install() {
  for (const key of ["requestAnimationFrame", "MessageChannel", "performance", "queueMicrotask"]) {
    saved.set(key, scope[key]);
  }
  now = 0;
  frames = [];
  messages = [];
  microtasks = [];
  Object.assign(scope, {
    requestAnimationFrame: (callback: () => void) => frames.push(callback),
    MessageChannel: TestChannel,
    performance: { now: () => now },
    queueMicrotask: (callback: () => void) => microtasks.push(callback),
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

test("the key's work ends after its input handlers' microtasks, before the frame and its rendering", () => {
  install();
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  now = 1;
  target.fire("keydown", composerKey(0));
  now = 3;
  target.fire("input");
  now = 4; // the editor's flush and React's render ran in the field's handlers' microtasks, before the document's
  run(microtasks);
  now = 12; // on Mac WebKit the frame runs next, then its style, layout and paint
  run(frames);
  now = 18;
  run(messages);
  expect(perf.typing).toHaveLength(1);
  expect(perf.typing[0]!.work).toBe(4);
  expect(perf.typing[0]!.frame).toBe(12);
  expect(perf.typing[0]!.paint).toBe(18);
  expect(typingSummary(perf.typing).to_work.p95_ms).toBe(4);
});

test("a key that edits nothing has no work sample, and a later edit is not counted for it", () => {
  install();
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  target.fire("keydown", composerKey(0));
  now = 7;
  run(frames);
  run(messages);
  now = 9;
  target.fire("input");
  run(microtasks);
  expect(perf.typing[0]!.work).toBeUndefined();
});

test("with a prioritized task API the paint mark is a user-blocking task, not a posted message behind later keys", () => {
  install();
  saved.set("scheduler", scope.scheduler);
  const tasks: { priority: string; run: () => void }[] = [];
  scope.scheduler = { postTask: (run: () => void, options: { priority: string }) => tasks.push({ run, ...options }) };
  const target = page();
  const perf = new AcpmuxPerf();
  perf.enable(target as unknown as Document);
  target.fire("keydown", composerKey(0));
  now = 10;
  run(frames);
  expect(messages).toHaveLength(0);
  expect(tasks.map((task) => task.priority)).toEqual(["user-blocking"]);
  now = 14;
  tasks.splice(0).forEach((task) => task.run());
  expect(perf.typing[0]!.frame).toBe(10);
  expect(perf.typing[0]!.paint).toBe(14);
});
