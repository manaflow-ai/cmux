import { expect, test } from "bun:test";
import { resolvePointerMenuPosition } from "../src/ui/anchor";

const viewport = { width: 800, height: 600 };
const size = { width: 180, height: 240 };

test("a menu that fits below starts at the pointer, including an exact fit", () => {
  const point = { x: 130, y: 356 };
  expect(resolvePointerMenuPosition(point, size, viewport)).toMatchObject({ left: 130, top: 356, side: "below" });
});

test("a bottom-right click anchors the opposite menu corner to the pointer", () => {
  const point = { x: 780, y: 550 };
  expect(resolvePointerMenuPosition(point, size, viewport)).toMatchObject({ left: 600, top: 310, side: "above" });
});

test("when neither side fits, the menu uses the roomier side and slides fully into view", () => {
  const tall = { width: 180, height: 400 };
  for (const [y, side, top] of [
    [280, "below", 196],
    [320, "above", 4],
  ] as const) {
    const placed = resolvePointerMenuPosition({ x: 130, y }, tall, viewport);
    expect(placed).toMatchObject({ left: 130, top, side });
    expect(placed.maxHeight).toBeGreaterThanOrEqual(tall.height);
  }
});

test("a window-height menu can show every row and an oversized menu stays in the window", () => {
  for (const height of [600, 720]) {
    const placed = resolvePointerMenuPosition({ x: 130, y: 320 }, { ...size, height }, viewport);
    expect(placed.top).toBeGreaterThanOrEqual(0);
    expect(placed.top + Math.min(height, placed.maxHeight)).toBeLessThanOrEqual(viewport.height);
    if (height === viewport.height) expect(placed.maxHeight).toBeGreaterThanOrEqual(height);
  }
});

test("an RTL menu attaches its right edge to the pointer and flips right at the left boundary", () => {
  const place = (x: number) => resolvePointerMenuPosition({ x, y: 80 }, size, viewport, 4, "rtl");
  expect(place(400).left).toBe(220);
  expect(place(40).left).toBe(40);
});
