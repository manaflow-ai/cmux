import { expect, test } from "bun:test";
import { lengthFits } from "./videoLengthFit";

const box = (left: number, top: number, width: number, height: number) => ({
  left,
  top,
  right: left + width,
  bottom: top + height,
});

test("a length in the corner of a 64 px chip, under its glyph, fits", () => {
  // 64 square, 24 px glyph in its middle, "0:32" at caption size 4 px in from the corner.
  expect(lengthFits(box(0, 0, 64, 64), box(29, 46, 31, 14), box(20, 20, 24, 24))).toBe(true);
});

test("Leo's 36 × 48 chip: the length over the glyph does not fit", () => {
  expect(lengthFits(box(0, 0, 36, 48), box(1, 30, 31, 14), box(6, 12, 24, 24))).toBe(false);
});

test("a length past the tile's edge does not fit", () => {
  expect(lengthFits(box(0, 0, 48, 64), box(-4, 46, 48, 14), box(12, 20, 24, 24))).toBe(false);
  expect(lengthFits(box(0, 0, 48, 64), box(10, 46, 37.5, 14))).toBe(false);
});

test("a queued tile's corner chip has no glyph apart: inside is enough", () => {
  expect(lengthFits(box(0, 0, 64, 36), box(13, 17, 47, 15))).toBe(true);
  expect(lengthFits(box(0, 0, 36, 36), box(-11, 17, 47, 15))).toBe(false);
});
