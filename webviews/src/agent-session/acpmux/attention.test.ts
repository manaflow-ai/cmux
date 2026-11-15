// The reader is at the chat while their hand moved on the page within the idle time (attention.ts):
// away once it passes untouched, back on the next input, and the timer does no work per move.
import { expect, test } from "bun:test";
import { createAttention, presentAt } from "./attention";

/// An event target and a clock the test drives: `fire` dispatches an input, `advance` moves time and
/// runs the timers that came due.
function harness(idleMs = 1000) {
  const handlers = new Map<string, Set<() => void>>();
  const target = {
    addEventListener: (name: string, fn: () => void) => {
      if (!handlers.has(name)) handlers.set(name, new Set());
      handlers.get(name)!.add(fn);
    },
    removeEventListener: (name: string, fn: () => void) => void handlers.get(name)?.delete(fn),
  } as unknown as Window;
  let clock = 0;
  let armed = 0;
  const due = new Map<number, { at: number; fn: () => void }>();
  let next = 0;
  const attention = createAttention(target, idleMs, () => clock, {
    set: (fn, ms) => {
      armed += 1;
      const id = ++next;
      due.set(id, { at: clock + ms, fn });
      return id;
    },
    clear: (id) => void due.delete(id as number),
  });
  let changes = 0;
  attention.subscribe(() => (changes += 1));
  const advance = (ms: number) => {
    const end = clock + ms;
    for (;;) {
      const first = [...due.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!first || first[1].at > end) break;
      due.delete(first[0]);
      clock = first[1].at;
      first[1].fn();
    }
    clock = end;
  };
  const fire = (name: string) => handlers.get(name)?.forEach((fn) => fn());
  return { attention, advance, fire, changes: () => changes, armed: () => armed, handlers };
}

test("a reader is here until the idle time passes untouched, then back on their next input", () => {
  const h = harness();
  expect(h.attention.present()).toBe(true);
  h.advance(999);
  expect(h.attention.present()).toBe(true);
  h.advance(1);
  expect(h.attention.present()).toBe(false);
  expect(h.changes()).toBe(1);
  h.fire("pointermove");
  expect(h.attention.present()).toBe(true);
  expect(h.changes()).toBe(2);
});

test("each kind of input keeps the reader here, and touch counts as one", () => {
  for (const input of ["pointermove", "pointerdown", "wheel", "keydown", "touchstart", "focus", "touch"]) {
    const h = harness();
    h.advance(900);
    if (input === "touch") h.attention.touch();
    else h.fire(input);
    h.advance(900);
    expect(h.attention.present()).toBe(true);
    h.advance(100);
    expect(h.attention.present()).toBe(false);
  }
});

test("moves arm no timer of their own: one per idle time at most", () => {
  const h = harness();
  for (let i = 0; i < 500; i++) {
    h.advance(1);
    h.fire("pointermove");
  }
  // 500 moves inside the first idle time: only the first timer.
  expect(h.armed()).toBe(1);
  // It fires at 1000 ms, finds the hand moved at 500 ms and re-arms once for what is left.
  h.advance(600);
  expect(h.armed()).toBe(2);
  expect(h.attention.present()).toBe(true);
  expect(h.changes()).toBe(0);
});

test("it listens only while subscribed: the last unsubscribe removes every listener", () => {
  const h = harness();
  const listening = () => [...h.handlers.values()].reduce((n, set) => n + set.size, 0);
  expect(listening()).toBeGreaterThan(0);
  const second = h.attention.subscribe(() => {});
  second();
  expect(listening()).toBeGreaterThan(0);
  h.attention.dispose();
  expect(listening()).toBe(0);
  // Unwatched, the reader counts as here and a touch arms nothing.
  expect(h.attention.present()).toBe(true);
  const armed = h.armed();
  h.attention.touch();
  expect(h.armed()).toBe(armed);
});

test("dispose stops listening and tells no one", () => {
  const h = harness();
  h.attention.dispose();
  expect([...h.handlers.values()].every((set) => set.size === 0)).toBe(true);
  h.advance(5000);
  expect(h.changes()).toBe(0);
});

test("presentAt is the idle rule", () => {
  expect(presentAt(0, 999, 1000)).toBe(true);
  expect(presentAt(0, 1000, 1000)).toBe(false);
});
