import { describe, expect, test } from "bun:test";
import { clampIntoColumn, edgeScrollStep, inGutter, pastThreshold, type GutterGeometry } from "./gutterSelect";

// A 1200 px view with a 760 px column centered in it, the bottom stack 120 px tall over its foot.
const geometry: GutterGeometry = {
  column: { left: 220, right: 980 },
  view: { left: 0, right: 1200, top: 40, bottom: 580 },
  lane: 16,
};

describe("gutter drag-to-select geometry", () => {
  test("only the margins either side of the column are gutter", () => {
    expect(inGutter(10, geometry)).toBe(true);
    expect(inGutter(219, geometry)).toBe(true);
    expect(inGutter(220, geometry)).toBe(false);
    expect(inGutter(600, geometry)).toBe(false);
    expect(inGutter(980, geometry)).toBe(false);
    expect(inGutter(981, geometry)).toBe(true);
    expect(inGutter(1183, geometry)).toBe(true);
  });

  test("the scrollbar's lane and points outside the view are not gutter", () => {
    expect(inGutter(1184, geometry)).toBe(false);
    expect(inGutter(1199, geometry)).toBe(false);
    expect(inGutter(-1, geometry)).toBe(false);
    expect(inGutter(1200, geometry)).toBe(false);
  });

  test("a gutter point reads one pixel inside the column, at its own height", () => {
    expect(clampIntoColumn(30, 300, geometry)).toEqual({ x: 221, y: 300 });
    expect(clampIntoColumn(1100, 300, geometry)).toEqual({ x: 979, y: 300 });
    expect(clampIntoColumn(500, 300, geometry)).toEqual({ x: 500, y: 300 });
  });

  test("a point above the view or under the bottom stack reads at the view's edge", () => {
    expect(clampIntoColumn(30, 0, geometry)).toEqual({ x: 221, y: 41 });
    expect(clampIntoColumn(1100, 690, geometry)).toEqual({ x: 979, y: 579 });
  });

  test("a column too narrow to clamp into reads at its middle", () => {
    const narrow = { ...geometry, column: { left: 300, right: 301 } };
    expect(clampIntoColumn(10, 300, narrow).x).toBe(300.5);
  });

  test("a press becomes a selection only past the threshold", () => {
    expect(pastThreshold(0, 0)).toBe(false);
    expect(pastThreshold(2, 2)).toBe(false);
    expect(pastThreshold(3, 0)).toBe(true);
    expect(pastThreshold(0, -4)).toBe(true);
  });

  test("the view scrolls only while the pointer is past its top or bottom", () => {
    expect(edgeScrollStep(300, geometry.view)).toBe(0);
    expect(edgeScrollStep(40, geometry.view)).toBe(0);
    expect(edgeScrollStep(580, geometry.view)).toBe(0);
    expect(edgeScrollStep(30, geometry.view)).toBe(-5);
    expect(edgeScrollStep(39, geometry.view)).toBe(-2);
    expect(edgeScrollStep(600, geometry.view)).toBe(10);
    expect(edgeScrollStep(5000, geometry.view)).toBe(40);
  });
});
