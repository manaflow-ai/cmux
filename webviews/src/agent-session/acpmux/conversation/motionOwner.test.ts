// The motion owner (motionOwner.ts; docs/design/transcript-motion-model.md rules 7 and 8): one
// transition reads the anchor, declares the move to the watcher, keeps the anchor on its pixel, and
// ends in one settle.
import { describe, expect, test } from "bun:test";
import { liveExpectations, resetLayoutWatch } from "./layoutWatch";
import { type MotionList, runningTransition, transition } from "./motionOwner";

const fakeTimers = () => {
  const pending = new Map<number, () => void>();
  let next = 0;
  return {
    timers: {
      set: (run: () => void) => (pending.set(++next, run), next),
      clear: (h: unknown) => void pending.delete(h as number),
    },
    fire: () => [...pending.values()].forEach((run) => run()),
    size: () => pending.size,
  };
};
const list = () => {
  const offsets = new Map([
    ["a", 0],
    ["b", 100],
    ["c", 200],
  ]);
  const log: string[] = [];
  const motion: MotionList = {
    offsetOf: (id) => offsets.get(id),
    scrollBy: (d) => {
      log.push(`scroll ${d}`);
      for (const [id, v] of offsets) offsets.set(id, v - d);
    },
    rowsAfter: (id) => [...offsets.keys()].filter((k) => k > id),
    settle: () => log.push("settle"),
  };
  return { motion, offsets, log };
};

describe("transition", () => {
  test("declares the move, keeps the anchor, settles once at its end", () => {
    resetLayoutWatch();
    const { motion, offsets, log } = list();
    const t = fakeTimers();
    const run = transition(
      motion,
      { cause: "disclosure", anchorRow: "b", ms: 200, apply: () => offsets.set("b", 130) },
      t.timers,
    );
    expect(run.anchor).toEqual({ rowId: "b", offsetPx: 100 });
    expect(run.rows).toEqual(["c"]);
    expect(offsets.get("b")).toBe(100);
    expect(log).toEqual(["scroll 30"]);
    expect(liveExpectations().some((e) => e.reason === "disclosure" && e.anchorRow === "b")).toBe(true);
    t.fire();
    expect(log).toEqual(["scroll 30", "settle"]);
    expect(run.ended).toBe(true);
    expect(runningTransition(motion)).toBeUndefined();
    expect(liveExpectations().some((e) => e.reason === "disclosure")).toBe(false);
  });
  test("a new transition on the same list ends the one before it first", () => {
    resetLayoutWatch();
    const { motion, log } = list();
    const t = fakeTimers();
    const first = transition(motion, { cause: "disclosure", anchorRow: "a", ms: 200 }, t.timers);
    const second = transition(motion, { cause: "turn-end", anchorRow: "b", ms: 200 }, t.timers);
    expect(first.ended).toBe(true);
    expect(log).toEqual(["settle"]);
    expect(runningTransition(motion)).toBe(second);
    expect(t.size()).toBe(1);
  });
  test("an unmounted anchor moves no scroll", () => {
    const { motion, log } = list();
    const run = transition(motion, { cause: "room", anchorRow: "zz", ms: 0 }, fakeTimers().timers);
    expect(run.anchor).toBeUndefined();
    expect(log).toEqual([]);
  });
});
