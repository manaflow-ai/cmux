import { expect, test } from "bun:test";
import type { Lanes } from "./schedule";
import { GAP_MS, listStoreFeed, STALE_MS } from "./listStoreFeed";
import type { AcpmuxSessionEntry } from "./sessionList";

/// A lane that holds idle work until the test runs it, and timers the test fires.
function fakes() {
  const idle = new Map<string, () => void>();
  const lanes = {
    idle: (key: string, fn: () => void) => void idle.set(key, fn),
    flush: (key?: string) => {
      for (const [k, fn] of Array.from(idle)) {
        if (key !== undefined && k !== key) continue;
        idle.delete(k);
        fn();
      }
    },
  } as unknown as Lanes;
  let now = 0;
  let timers: { at: number; cb: () => void; id: number }[] = [];
  let ids = 0;
  return {
    idle,
    lanes: () => lanes,
    timers: {
      set: (cb: () => void, ms: number) => {
        timers.push({ at: now + ms, cb, id: (ids += 1) });
        return ids;
      },
      clear: (id: unknown) => void (timers = timers.filter((t) => t.id !== id)),
      now: () => now,
    },
    /// Moves the clock `ms` on and fires the timers due.
    tick: (ms: number) => {
      now += ms;
      for (const t of timers.filter((t) => t.at <= now)) {
        timers = timers.filter((x) => x !== t);
        t.cb();
      }
    },
  };
}

const list = (...ids: string[]) => ids.map((sessionId) => ({ sessionId }) as AcpmuxSessionEntry);

test("the first list goes in at once, later ones on the idle lane, coalesced to the newest", () => {
  const given: string[][] = [];
  const store = { set: (sessions: readonly AcpmuxSessionEntry[]) => void given.push(sessions.map((s) => s.sessionId)) };
  const f = fakes();
  const feed = listStoreFeed(store, f.lanes, f.timers);
  feed.give(list("a"));
  expect(given).toEqual([["a"]]);
  f.tick(GAP_MS);
  feed.give(list("a", "b"));
  feed.give(list("a", "b", "c"));
  // Nothing on the frame path: both wait in the idle lane under one key.
  expect(given).toEqual([["a"]]);
  expect(f.idle.size).toBe(1);
  f.lanes().flush();
  expect(given).toEqual([["a"], ["a", "b", "c"]]);
});

test("an empty first list leaves the next one on the frame too", () => {
  const given: number[] = [];
  const f = fakes();
  const feed = listStoreFeed({ set: (s) => void given.push(s.length) }, f.lanes, f.timers);
  feed.give([]);
  feed.give(list("a"));
  expect(given).toEqual([0, 1]);
  expect(f.idle.size).toBe(0);
});

test("a list the idle lane has not run within STALE_MS goes in then", () => {
  const given: number[] = [];
  const f = fakes();
  const feed = listStoreFeed({ set: (s) => void given.push(s.length) }, f.lanes, f.timers);
  feed.give(list("a"));
  f.tick(GAP_MS);
  feed.give(list("a", "b"));
  f.tick(STALE_MS);
  expect(given).toEqual([1, 2]);
  expect(f.idle.size).toBe(0);
});

test("lists given within GAP_MS of a rebuild wait for it, then rebuild once", () => {
  const given: number[] = [];
  const f = fakes();
  const feed = listStoreFeed({ set: (s) => void given.push(s.length) }, f.lanes, f.timers);
  feed.give(list("a"));
  feed.give(list("a", "b"));
  feed.give(list("a", "b", "c"));
  f.tick(GAP_MS - 1);
  expect(f.idle.size).toBe(0);
  f.tick(1);
  expect(f.idle.size).toBe(1);
  f.lanes().flush();
  expect(given).toEqual([1, 3]);
});
