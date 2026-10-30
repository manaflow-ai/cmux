// The room a collapse keeps under the rows (foldAnchor.ts), so closing a disclosure at the
// transcript's end never clamps the offset and brings the clicked line down (Leo, ask-a736047107:
// "WHEN I EXPAND THEM IT JUMPS ME DOWN AND WHEN I COLLAPSE IT JUMPS ME UP").
import { describe, expect, test } from "bun:test";
import { foldRoomFor, trimmedFoldRoom } from "./foldAnchor";

describe("foldRoomFor", () => {
  test("keeps the view's end, whole pixels up", () => {
    expect(foldRoomFor(1200.4, 600)).toBe(1801);
  });
  test("never shrinks an end already kept further down", () => {
    expect(foldRoomFor(100, 600, 2000)).toBe(2000);
  });
});

describe("trimmedFoldRoom", () => {
  test("stays as it is while a fold holds its line", () => {
    expect(trimmedFoldRoom(1800, 1500, 1200, true)).toBe(1800);
  });
  test("follows the view's end up as the reader scrolls up", () => {
    expect(trimmedFoldRoom(1800, 1500, 1200, false)).toBe(1500);
  });
  test("never grows past what was kept", () => {
    expect(trimmedFoldRoom(1800, 1900, 1200, false)).toBe(1800);
  });
  test("goes once the rows reach it", () => {
    expect(trimmedFoldRoom(1800, 1800, 1800, false)).toBe(0);
    expect(trimmedFoldRoom(1800, 1500, 1600, false)).toBe(0);
  });
  test("nothing kept stays nothing", () => {
    expect(trimmedFoldRoom(0, 1500, 1200, false)).toBe(0);
  });
});
