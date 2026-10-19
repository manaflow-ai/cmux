// The status glyphs' 1x pixel art fits a 10-pixel grid only: a 10 px glyph on a 3x screen (30 device
// pixels) draws the master's curves, not the art blown up in blocks (review on #20410).
import { expect, test } from "bun:test";
import { usesPixelArt } from "../src/ui/StatusGlyph";

test("only a glyph of exactly 10 device pixels takes the 1x pixel art", () => {
  expect(usesPixelArt(10, 1)).toBe(true);
  expect(usesPixelArt(5, 2)).toBe(true);
  for (const [size, ratio] of [
    [10, 2],
    [10, 3],
    [10, 5],
    [15, 2],
  ] as const) {
    expect(`${size}x${ratio} ${usesPixelArt(size, ratio)}`).toBe(`${size}x${ratio} false`);
  }
});
