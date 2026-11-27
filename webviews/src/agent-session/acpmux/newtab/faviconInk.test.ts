import { expect, test } from "bun:test";
import { inkOf } from "./faviconInk";

/// A 4x4 RGBA image: `ink` pixels of colour `rgb` on a transparent ground, the rest of `rest` (if given).
function image(rgb: [number, number, number], ink = 8, rest?: [number, number, number]): number[] {
  const pixels: number[] = [];
  for (let index = 0; index < 16; index++) {
    if (index < ink) pixels.push(...rgb, 255);
    else if (rest) pixels.push(...rest, 255);
    else pixels.push(0, 0, 0, 0);
  }
  return pixels;
}

// The GitHub mark vanished on the dark New Tab rows (Lucas 2026-11-26): a one-colour dark favicon reads
// "dark", so the dark theme draws it in the label colour.
test("a one-colour black favicon has a dark ink", () => {
  expect(inkOf(image([24, 23, 23]))).toBe("dark");
});

test("a one-colour white favicon has a light ink", () => {
  expect(inkOf(image([250, 250, 250]))).toBe("light");
});

test("a colourful favicon draws as is", () => {
  expect(inkOf(image([66, 133, 244]))).toBeUndefined();
  // Black and white together (a white mark on a black tile) is no single ink either.
  expect(inkOf(image([0, 0, 0], 8, [255, 255, 255]))).toBeUndefined();
});

test("a transparent favicon draws as is", () => {
  expect(inkOf(image([0, 0, 0], 0))).toBeUndefined();
});

test("the antialiased fringe does not count as ink", () => {
  const pixels = image([20, 20, 20]);
  // A half-transparent coloured fringe pixel.
  pixels.splice(60, 4, 255, 0, 0, 100);
  expect(inkOf(pixels)).toBe("dark");
});

// Vercel's black disc with a white triangle: a tint would fill the triangle, so it is a tile (inverted).
test("a one-ink tile with a knockout is a tile, not a mark", () => {
  expect(inkOf(image([0, 0, 0], 15, [255, 255, 255]))).toBe("dark-tile");
  expect(inkOf(image([255, 255, 255], 15, [0, 0, 0]))).toBe("light-tile");
});

// A grey mark in a black tile is off the ink but not its opposite: still a tile, never filled by a tint.
test("an opaque tile with a grey mark is a tile", () => {
  expect(inkOf(image([0, 0, 0], 15, [120, 120, 120]))).toBe("dark-tile");
});
