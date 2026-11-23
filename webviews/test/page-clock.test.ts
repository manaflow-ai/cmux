import { afterEach, expect, jest, test } from "bun:test";
import { pageClocks, subscribePageDeadline, visibleInterval } from "../src/ui/pageClock";
import { pageLoops } from "../src/ui/pageLoops";

type FakeDocument = Document & { show(state: DocumentVisibilityState): void };
const original = Object.getOwnPropertyDescriptor(globalThis, "document");

function installDocument(state: DocumentVisibilityState): FakeDocument {
  const listeners = new Map<string, Set<() => void>>();
  const doc = {
    visibilityState: state,
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const set = listeners.get(type) ?? new Set();
      set.add(listener as () => void);
      listeners.set(type, set);
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      listeners.get(type)?.delete(listener as () => void);
    },
    show(next: DocumentVisibilityState) {
      Object.defineProperty(doc, "visibilityState", { value: next, configurable: true });
      for (const listener of listeners.get("visibilitychange") ?? []) listener();
    },
  } as unknown as FakeDocument;
  Object.defineProperty(globalThis, "document", { value: doc, configurable: true });
  return doc;
}

afterEach(() => {
  jest.useRealTimers();
  if (original) Object.defineProperty(globalThis, "document", original);
  else delete (globalThis as { document?: unknown }).document;
});

test("visibleInterval owns one timer and releases it while hidden", () => {
  jest.useFakeTimers();
  const doc = installDocument("visible");
  let ticks = 0;
  const stop = visibleInterval("test", () => ticks++, 1000);
  expect(pageClocks(doc)).toMatchObject({ running: 1, subscribers: 1 });
  expect(pageLoops(doc)).toMatchObject({ loops: 1, hidden_loops: 0 });
  doc.show("hidden");
  expect(pageClocks(doc)).toMatchObject({ running: 0, subscribers: 1 });
  expect(pageLoops(doc)).toMatchObject({ loops: 0, hidden_loops: 0 });
  jest.advanceTimersByTime(2000);
  expect(ticks).toBe(0);
  doc.show("visible");
  jest.advanceTimersByTime(999);
  expect(ticks).toBe(0);
  jest.advanceTimersByTime(1);
  expect(ticks).toBe(1);
  stop();
  expect(pageClocks(doc)).toEqual({ running: 0, subscribers: 0, items: [] });
});

test("timestamp deadlines share the nearest timer and stop when no label will change", () => {
  jest.useFakeTimers();
  jest.setSystemTime(0);
  const doc = installDocument("visible");
  let first = 0;
  let second = 0;
  const stopFirst = subscribePageDeadline(
    () => first++,
    () => (Date.now() < 120_000 ? 120_000 : Infinity),
  );
  const stopSecond = subscribePageDeadline(
    () => second++,
    () => 3_600_000,
  );
  expect(pageClocks(doc)).toMatchObject({ running: 1, subscribers: 2 });
  jest.advanceTimersByTime(60_000);
  expect(first).toBe(0);
  expect(second).toBe(0);
  stopSecond();
  jest.advanceTimersByTime(60_005);
  expect(first).toBe(1);
  stopFirst();
  const stopStatic = subscribePageDeadline(
    () => first++,
    () => Infinity,
  );
  expect(pageClocks(doc)).toMatchObject({ running: 0, subscribers: 1 });
  stopStatic();
  expect(pageClocks(doc)).toEqual({ running: 0, subscribers: 0, items: [] });
});

// A chat switch unmounts one chat's timestamp labels and mounts the next one's: each join or leave
// rebuilt the timer and scanned every label for the nearest deadline, quadratic in the rows
// (bench/settled-page.bench.ts chat_switch). A join rebuilds only for a label due before the timer.
test("timestamp labels join and leave without rebuilding the shared timer, and still wake on time", () => {
  jest.useFakeTimers();
  jest.setSystemTime(0);
  const doc = installDocument("visible");
  let built = 0;
  const realAdd = doc.addEventListener.bind(doc);
  doc.addEventListener = ((type: string, listener: EventListenerOrEventListenerObject) => {
    if (type === "visibilitychange") built += 1;
    realAdd(type, listener);
  }) as typeof doc.addEventListener;
  const woke: number[] = [];
  const stops: (() => void)[] = [];
  for (let row = 0; row < 400; row += 1)
    stops.push(
      subscribePageDeadline(
        () => woke.push(row),
        () => (Date.now() < 120_000 ? 120_000 + (row % 3) * 60_000 : Infinity),
      ),
    );
  expect(built).toBe(1);
  expect(pageClocks(doc)).toMatchObject({ running: 1, subscribers: 400 });
  // An earlier label moves the timer up.
  let early = 0;
  const stopEarly = subscribePageDeadline(
    () => early++,
    () => (Date.now() < 60_000 ? 60_000 : Infinity),
  );
  expect(built).toBe(2);
  // Leaving rebuilds nothing until the last label goes.
  for (const stop of stops.splice(200)) stop();
  expect(built).toBe(2);
  jest.advanceTimersByTime(60_005);
  expect(early).toBe(1);
  expect(woke).toEqual([]);
  stopEarly();
  jest.advanceTimersByTime(60_000);
  expect(woke.length).toBe(Math.ceil(200 / 3));
  for (const stop of stops) stop();
  expect(pageClocks(doc)).toEqual({ running: 0, subscribers: 0, items: [] });
});
