import { describe, expect, test } from "bun:test";
import { LATE_MS, LOAD_EMIT_MS, ON_TIME_TO_RECOVER, coalescedUnderLoad } from "./loadCoalesce";

function harness() {
  let now = 0;
  const frames: (() => void)[] = [];
  const timers: { at: number; run: () => void }[] = [];
  const schedule = coalescedUnderLoad((run) => void frames.push(run), {
    now: () => now,
    later: (run, ms) => {
      const timer = { at: now + ms, run };
      timers.push(timer);
      return timer;
    },
    clear: (handle) => void timers.splice(timers.indexOf(handle as (typeof timers)[number]), 1),
  });
  return {
    schedule,
    frames,
    timers,
    /// Advance the clock by `ms` and draw the waiting frame.
    frameAfter(ms: number) {
      now += ms;
      frames.shift()?.();
    },
    fireTimers(at: number) {
      now = at;
      for (const timer of timers.splice(0)) timer.run();
    },
  };
}

describe("coalescedUnderLoad", () => {
  test("on-time frames draw every frame", () => {
    const h = harness();
    let drawn = 0;
    for (let i = 0; i < 5; i++) {
      h.schedule(() => drawn++);
      expect(h.timers).toHaveLength(0);
      h.frameAfter(16);
    }
    expect(drawn).toBe(5);
  });

  test("a late frame holds the next snapshot until LOAD_EMIT_MS after it drew", () => {
    const h = harness();
    let drawn = 0;
    h.schedule(() => drawn++);
    h.frameAfter(LATE_MS + 10);
    const drewAt = LATE_MS + 10;
    h.schedule(() => drawn++);
    expect(h.frames).toHaveLength(0);
    expect(h.timers[0]?.at).toBe(drewAt + LOAD_EMIT_MS);
    h.fireTimers(drewAt + LOAD_EMIT_MS);
    h.frameAfter(16);
    expect(drawn).toBe(2);
  });

  test("on-time frames in a row end the coalescing", () => {
    const h = harness();
    h.schedule(() => {});
    h.frameAfter(LATE_MS);
    for (let i = 0; i < ON_TIME_TO_RECOVER; i++) {
      h.schedule(() => {});
      h.fireTimers(h.timers[0]!.at);
      h.frameAfter(16);
    }
    h.schedule(() => {});
    expect(h.timers).toHaveLength(0);
    expect(h.frames).toHaveLength(1);
  });

  test("cancel stops a held snapshot", () => {
    const h = harness();
    h.schedule(() => {});
    h.frameAfter(LATE_MS);
    let drawn = false;
    const cancel = h.schedule(() => (drawn = true));
    cancel?.();
    expect(h.timers).toHaveLength(0);
    h.frameAfter(16);
    expect(drawn).toBe(false);
  });
});
