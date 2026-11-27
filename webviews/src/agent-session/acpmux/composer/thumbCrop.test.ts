import { expect, test } from "bun:test";
import { cropAxis } from "./thumbCrop";

test("a picture wider than its tile is cut on the right, a taller one at the bottom", () => {
  // Leo's tile: a 1400×90 screenshot strip in a 128×48 thumbnail.
  expect(cropAxis({ width: 1400, height: 90 }, { width: 128, height: 48 })).toBe("x");
  expect(cropAxis({ width: 90, height: 1400 }, { width: 48, height: 48 })).toBe("y");
});

test("a picture of its tile's shape, or a size not known yet, is not cut", () => {
  expect(cropAxis({ width: 256, height: 96 }, { width: 128, height: 48 })).toBeUndefined();
  expect(cropAxis({ width: 257, height: 96 }, { width: 128, height: 48 })).toBeUndefined();
  expect(cropAxis({ width: 0, height: 0 }, { width: 128, height: 48 })).toBeUndefined();
  expect(cropAxis({ width: 400, height: 90 }, { width: 0, height: 48 })).toBeUndefined();
});
