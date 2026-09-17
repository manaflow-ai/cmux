import { describe, expect, test } from "bun:test";
import { sharePointerCoordinates } from "../services/share/pointerCoordinates";

const bounds = { left: 80, top: 120, width: 400, height: 200 };

describe("shared pointer coordinates", () => {
  test("uses a top-left origin without flipping Y", () => {
    expect(sharePointerCoordinates(80, 120, bounds)).toEqual({ x: 0, y: 0 });
    expect(sharePointerCoordinates(280, 170, bounds)).toEqual({ x: 0.5, y: 0.25 });
    expect(sharePointerCoordinates(480, 320, bounds)).toEqual({ x: 1, y: 1 });
  });

  test("ignores movement in surrounding cmux chrome and chat", () => {
    expect(sharePointerCoordinates(280, 119, bounds)).toBeNull();
    expect(sharePointerCoordinates(280, 321, bounds)).toBeNull();
    expect(sharePointerCoordinates(79, 220, bounds)).toBeNull();
    expect(sharePointerCoordinates(481, 220, bounds)).toBeNull();
  });

  test("rejects unusable geometry", () => {
    expect(sharePointerCoordinates(80, 120, { ...bounds, height: 0 })).toBeNull();
    expect(sharePointerCoordinates(Number.NaN, 120, bounds)).toBeNull();
  });
});
