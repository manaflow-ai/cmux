import { expect, test } from "bun:test";
import { noteOlderScrollTarget, olderScrollTargetTop } from "./olderScrollTarget";

test("keeps a native scrollbar target while the older-history room drains", () => {
  expect(noteOlderScrollTarget(undefined, 640, 1_000, true)).toBe(640);
  expect(noteOlderScrollTarget(640, 420, 800, true)).toBe(420);
  expect(olderScrollTargetTop(420, 800)).toBe(800);
  expect(olderScrollTargetTop(420, 300)).toBe(420);
  expect(olderScrollTargetTop(undefined, 800)).toBeUndefined();
});

test("does not capture layout or wheel positions at the loaded edge", () => {
  expect(noteOlderScrollTarget(undefined, 999.8, 1_000, true)).toBeUndefined();
  expect(noteOlderScrollTarget(undefined, 640, 1_000, false)).toBeUndefined();
  expect(noteOlderScrollTarget(640, 900, 1_000, false)).toBe(640);
});
