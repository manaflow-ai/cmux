import { expect, test } from "bun:test";
import { countLine, hoursLine, hoursShare, type KeepCount, nextLine } from "./keepCount";

// keep_count.rs's wire answer for Plus, 2 kept, 41 hours (its wire-shape test holds the same).
const plus2: KeepCount = {
  plan: "plus",
  kept: 2,
  slots: 3,
  hoursUsed: 41,
  hours: 100,
  window: "month",
  hoursLow: false,
  next: { do: "keeps", after: 3 },
};

test("2 of 3 kept, 41 of 100 hours, and another keeps the third", () => {
  expect(countLine(plus2)).toEqual({ key: "keepCount.ofSlots", values: { kept: 2, slots: 3 } });
  expect(hoursLine(plus2)).toEqual({ key: "keepCount.hours", values: { used: 41, hours: 100 } });
  expect(nextLine(plus2)).toEqual({ key: "keepCount.next.keeps", values: { after: 3, slots: 3 } });
  expect(hoursShare(plus2)).toBeCloseTo(0.41);
});

test("no plan shows no count and says turning it on starts the taste", () => {
  const none: KeepCount = {
    ...plus2,
    plan: null,
    kept: 0,
    slots: 0,
    hoursUsed: null,
    hours: null,
    window: null,
    next: { do: "startsTrial", slots: 1, hours: 10 },
  };
  expect(countLine(none)).toBeUndefined();
  expect(hoursLine(none)).toBeUndefined();
  expect(hoursShare(none)).toBeUndefined();
  expect(nextLine(none)).toEqual({ key: "keepCount.next.startsTrial", values: { slots: 1, hours: 10 } });
});

test("the taste counts its hours over the week and spent hours clamp the share", () => {
  const trial: KeepCount = { ...plus2, plan: "trial", slots: 1, hours: 10, hoursUsed: 12, window: "week" };
  expect(hoursLine(trial)?.key).toBe("keepCount.hoursWeek");
  expect(hoursShare(trial)).toBe(1);
  expect(nextLine({ ...plus2, next: { do: "full" } }).key).toBe("keepCount.next.full");
  expect(nextLine({ ...plus2, next: { do: "hoursUsedUp" } }).key).toBe("keepCount.next.hoursUsedUp");
  expect(nextLine({ ...plus2, next: { do: "frees", after: 1 } })).toEqual({
    key: "keepCount.next.frees",
    values: { after: 1, slots: 3 },
  });
});
