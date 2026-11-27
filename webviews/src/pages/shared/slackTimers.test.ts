import { describe, expect, test } from "bun:test";

import { HEARTBEAT_MS } from "./pageHealth";
import { RIDE_SLACK_MS, SlackTimers } from "./slackTimers";

function fakeClock() {
  let now = 0;
  let seq = 0;
  const timers = new Map<number, { at: number; callback: () => void }>();
  let wakes = 0;
  const clock = {
    now: () => now,
    set: (callback: () => void, ms: number) => {
      timers.set(++seq, { at: now + ms, callback });
      return seq;
    },
    clear: (handle: unknown) => void timers.delete(handle as number),
  };
  /** Moves time to `to`, firing every page timer due on the way (each one is a wakeup). */
  const advance = (to: number, beatsEvery?: { ms: number; ride: () => void; from: number }) => {
    for (;;) {
      let next: [number, { at: number; callback: () => void }] | undefined;
      for (const entry of timers) if (!next || entry[1].at < next[1].at) next = entry;
      let beat = Infinity;
      if (beatsEvery)
        beat = beatsEvery.from + Math.ceil((now + 1e-9 - beatsEvery.from) / beatsEvery.ms) * beatsEvery.ms;
      if (beat <= now) beat += beatsEvery!.ms;
      const at = Math.min(next?.[1].at ?? Infinity, beat);
      if (at > to) break;
      now = at;
      wakes++;
      if (next && next[1].at === at) {
        timers.delete(next[0]);
        next[1].callback();
      } else beatsEvery!.ride();
    }
    now = to;
  };
  return { clock, advance, timers, wakes: () => wakes };
}

describe("SlackTimers", () => {
  test("its slack spans a heartbeat, so a job's window always holds one", () => {
    expect(RIDE_SLACK_MS).toBeGreaterThan(HEARTBEAT_MS);
  });

  test("jobs whose windows overlap share one wakeup", () => {
    const { clock, advance, wakes } = fakeClock();
    const timers = new SlackTimers(clock);
    const ran: string[] = [];
    timers.later(() => ran.push("snapshot"), 1_500);
    timers.later(() => ran.push("budget"), 2_000);
    advance(10_000);
    expect(ran).toEqual(["snapshot", "budget"]);
    expect(wakes()).toBe(1);
  });

  test("on a beating page the jobs ride the beats and never wake it themselves", () => {
    const { clock, advance, wakes } = fakeClock();
    const timers = new SlackTimers(clock);
    const ran: string[] = [];
    // The chat at rest after a switch (bench/chat-switch.bench.ts): beats every 2 s from 0.7 s.
    timers.later(() => ran.push("snapshot"), 1_500);
    timers.later(() => ran.push("budget"), 2_000);
    timers.later(() => ran.push("tally"), 5_000, 5_000);
    advance(5_000 + 4_000, { ms: HEARTBEAT_MS, from: 700, ride: () => timers.ride() });
    expect(ran).toEqual(["snapshot", "budget", "tally"]);
    // The beats only: 0.7 s, 2.7 s, ... 8.7 s.
    expect(wakes()).toBe(5);
    expect(timers.size).toBe(0);
  });

  test("a job never runs before its window opens", () => {
    const { clock, advance } = fakeClock();
    const timers = new SlackTimers(clock);
    let ran = false;
    timers.later(() => (ran = true), 3_000);
    advance(1_000);
    timers.ride();
    expect(ran).toBe(false);
    advance(3_000);
    timers.ride();
    expect(ran).toBe(true);
  });

  test("a cancelled job leaves no timer behind", () => {
    const { clock, timers: page } = fakeClock();
    const timers = new SlackTimers(clock);
    const id = timers.later(() => {}, 1_000);
    expect(page.size).toBe(1);
    timers.cancel(id);
    expect(page.size).toBe(0);
    expect(timers.size).toBe(0);
  });

  test("a job that throws does not keep the others from running", () => {
    const { clock, advance } = fakeClock();
    const timers = new SlackTimers(clock);
    const thrown: unknown[] = [];
    const original = globalThis.queueMicrotask;
    globalThis.queueMicrotask = (callback) => {
      try {
        callback();
      } catch (error) {
        thrown.push(error);
      }
    };
    try {
      let ran = false;
      timers.later(() => {
        throw new Error("boom");
      }, 100);
      timers.later(() => (ran = true), 100);
      advance(5_000);
      expect(ran).toBe(true);
      expect(thrown).toHaveLength(1);
    } finally {
      globalThis.queueMicrotask = original;
    }
  });

  test("the beat that rests the page runs the jobs that waited for quiet, so none wakes it after", () => {
    const { clock, advance, timers: page, wakes } = fakeClock();
    const timers = new SlackTimers(clock);
    const ran: [string, boolean][] = [];
    timers.later((atRest) => ran.push(["tally", atRest]), 5_000, 5_000, { atRest: true });
    timers.later((atRest) => ran.push(["budget", atRest]), 2_000, RIDE_SLACK_MS, { atRest: true });
    advance(HEARTBEAT_MS);
    timers.rest();
    expect(ran).toEqual([
      ["tally", true],
      ["budget", false],
    ]);
    expect(page.size).toBe(0);
    advance(20_000);
    expect(wakes()).toBe(0);
  });

  test("a job that did not ask for atRest keeps its window when the page rests", () => {
    const { clock, advance } = fakeClock();
    const timers = new SlackTimers(clock);
    let ran = 0;
    timers.later(() => ran++, 3_000);
    advance(HEARTBEAT_MS);
    timers.rest();
    expect(ran).toBe(0);
    advance(10_000);
    expect(ran).toBe(1);
  });

  test("an atRest job that asks again from its run waits for the next wake", () => {
    const { clock, advance } = fakeClock();
    const timers = new SlackTimers(clock);
    let runs = 0;
    const ask = () =>
      timers.later(
        () => {
          runs++;
          if (runs < 5) ask();
        },
        1_000,
        RIDE_SLACK_MS,
        { atRest: true },
      );
    ask();
    timers.rest();
    expect(runs).toBe(1);
    expect(timers.size).toBe(1);
    advance(1_000 + RIDE_SLACK_MS);
    expect(runs).toBe(2);
  });
});

// Leo (2026-11-26): "you guys can probably be aware of who's idle and who's not pretty reliably". A job
// with nothing to do on a resting page (the frame budget's return to full motion) arms no timer while the
// page rests, and runs on the wake that ends the rest.
test("a whenAwake job never wakes a resting page, and runs on the wake that ends the rest", () => {
  const { clock, advance, timers, wakes } = fakeClock();
  const scheduler = new SlackTimers(clock);
  scheduler.rest();
  const runs: boolean[] = [];
  scheduler.later((atRest) => runs.push(atRest), 2_000, undefined, { atRest: true, whenAwake: true });
  expect(timers.size).toBe(0);
  advance(60_000);
  expect(wakes()).toBe(0);
  expect(runs).toEqual([]);
  scheduler.wake();
  expect(runs).toEqual([false]);
  expect(scheduler.size).toBe(0);
});

test("a whenAwake job not yet due when the page wakes keeps its timer", () => {
  const { clock, advance, timers } = fakeClock();
  const scheduler = new SlackTimers(clock);
  scheduler.rest();
  let ran = 0;
  scheduler.later(() => ran++, 2_000, 0, { whenAwake: true });
  advance(500);
  scheduler.wake();
  expect(ran).toBe(0);
  expect(timers.size).toBe(1);
  advance(2_000);
  expect(ran).toBe(1);
});
