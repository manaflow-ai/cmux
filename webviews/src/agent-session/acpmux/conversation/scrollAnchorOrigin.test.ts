import { expect, test } from "bun:test";
import { fractionalAnchorCorrection } from "./scrollAnchorOrigin";

test("keeps a fractional anchor bounded across repeated positive growth and reversal", () => {
  let physical = 100;
  let origin = 0;
  let rowTop = 500;
  const visual = rowTop - physical;
  for (const delta of [...Array.from({ length: 100 }, () => 0.25), ...Array.from({ length: 100 }, () => -0.25)]) {
    const previousPhysicalTop = physical;
    rowTop += delta;
    const next = fractionalAnchorCorrection({
      previousPhysicalTop,
      previousOrigin: origin,
      layoutDelta: delta,
      actualPhysicalTop: Math.round(previousPhysicalTop - origin + delta),
    });
    physical = Math.round(next.desiredLogicalTop + next.origin);
    origin = next.origin;
    expect(rowTop + origin - physical).toBeCloseTo(visual, 10);
    expect(Math.abs(origin)).toBeLessThanOrEqual(0.5);
  }
  expect(rowTop).toBe(500);
  expect(physical).toBe(100);
  expect(origin).toBe(0);
});

test("rebases instead of carrying a clamp or stale-write residual", () => {
  expect(
    fractionalAnchorCorrection({
      previousPhysicalTop: 100,
      previousOrigin: -0.25,
      layoutDelta: 0.25,
      actualPhysicalTop: 140,
    }),
  ).toEqual({ desiredLogicalTop: 140, origin: 0 });
});
