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
