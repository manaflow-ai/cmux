import { expect, test } from "bun:test";
import { narrowKeyKind, overlaps, truncated } from "../src/gallery/narrowLayout";

const box = (left: number, top: number, width: number, height: number) => ({
  left,
  top,
  right: left + width,
  bottom: top + height,
});

test("a label under a button overlaps; side by side, or touching by a line's pixel, does not", () => {
  expect(overlaps(box(0, 0, 100, 16), box(80, 0, 24, 16))).toBe(true);
  expect(overlaps(box(0, 0, 100, 16), box(100, 0, 24, 16))).toBe(false);
  // Two lines of one paragraph with a tight line height share 2 px: no reader sees it.
  expect(overlaps(box(0, 0, 200, 18), box(0, 16, 200, 18))).toBe(false);
  // A 3 px sliver of a 20 px line is under a quarter of it.
  expect(overlaps(box(0, 0, 200, 20), box(0, 17, 200, 20))).toBe(false);
  expect(overlaps(box(0, 0, 200, 20), box(10, 8, 40, 20))).toBe(true);
});

test("an ellipsis box cuts only when its text is wider, or clamped and taller", () => {
  expect(truncated({ scrollWidth: 120, clientWidth: 100, scrollHeight: 16, clientHeight: 16 }, false)).toBe(true);
  expect(truncated({ scrollWidth: 101, clientWidth: 100, scrollHeight: 16, clientHeight: 16 }, false)).toBe(false);
  expect(truncated({ scrollWidth: 100, clientWidth: 100, scrollHeight: 48, clientHeight: 32 }, true)).toBe(true);
  expect(truncated({ scrollWidth: 100, clientWidth: 100, scrollHeight: 48, clientHeight: 32 }, false)).toBe(false);
});

test("a key's list positions and generated ids are blanked", () => {
  expect(narrowKeyKind('ellipsis:span.title in [data-row-id="tool-12"]')).toBe(
    'ellipsis:span.title in [data-row-id="tool-#"]',
  );
  expect(narrowKeyKind('overlap:div in [data-id="a1b2c3d4e5"] / button')).toBe('overlap:div in [data-id="#"] / button');
});
