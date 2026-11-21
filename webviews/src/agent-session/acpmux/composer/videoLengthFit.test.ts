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

test("a queued tile's corner chip carries its glyph: inside and clear of the tile's centre", () => {
  // 64 × 36 wide tile, the chip 12 tall 4 px up from the bottom: under the middle row (18).
  expect(lengthFits(box(0, 0, 64, 36), box(12, 20, 48, 12))).toBe(true);
  // The same chip 14 tall reaches the middle row: it would sit over the poster's centre.
  expect(lengthFits(box(0, 0, 64, 36), box(12, 18, 48, 14))).toBe(false);
  expect(lengthFits(box(0, 0, 36, 36), box(-11, 20, 47, 12))).toBe(false);
});
