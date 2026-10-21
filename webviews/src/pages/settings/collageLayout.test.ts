// Collage editor geometry (backgrounds plan phase 7): moves and resizes stay on the canvas and
// snap to halves and thirds; layouts frame the first pictures; restacking keeps every picture.
import { expect, test } from "bun:test";
import { arranged, moved, placed, resized, restacked, snap } from "./components/collageLayout";

const layer = { source: "starryNight", x: 0.1, y: 0.1, width: 0.3, height: 0.3, opacity: 1, cornerRadius: 0 };

test("edges snap to the canvas's halves and thirds, and only within reach", () => {
  expect(snap(0.495)).toBe(0.5);
  expect(snap(0.34)).toBeCloseTo(1 / 3);
  expect(snap(0.42)).toBe(0.42);
  // Moved so its left edge lands near the middle: it snaps there.
  expect(moved(layer, 0.39, 0).x).toBe(0.5);
  // Moved so its right edge lands near the right edge: it snaps flush.
  expect(moved(layer, 0.595, 0).x + layer.width).toBeCloseTo(1);
});

test("a picture never leaves the canvas, and never shrinks to nothing", () => {
  const far = moved(layer, 5, -5);
  expect(far.x).toBeCloseTo(1 - layer.width);
  expect(far.y).toBe(0);
  const big = resized(layer, 5, 5);
  expect(big.x + big.width).toBeCloseTo(1);
  expect(big.y + big.height).toBeCloseTo(1);
  const tiny = resized(layer, -5, -5);
  expect(tiny.width).toBe(0.05);
  expect(tiny.height).toBe(0.05);
});

test("layouts frame the first pictures and restacking keeps them all", () => {
  const collage = { name: "", fill: "#000000", layers: [placed("a", 0), placed("b", 1), placed("c", 2)] };
  const two = arranged(collage, "two");
  expect(two.layers[0]!.x).toBeLessThan(0.1);
  expect(two.layers[1]!.x).toBeGreaterThan(0.5);
  expect(two.layers[2]).toEqual(collage.layers[2]);
  const mosaic = arranged(collage, "mosaic");
  expect(mosaic.layers[0]!.width).toBeGreaterThan(mosaic.layers[1]!.width);
  const stacked = restacked(collage.layers, 0, 2);
  expect(stacked.map((l) => l.source)).toEqual(["b", "c", "a"]);
  expect(restacked(collage.layers, 0, -1)).toBe(collage.layers);
});
