// Which wheel events are a mouse wheel's notch (wheelGlide.ts): the values each engine dispatches.
import { describe, expect, test } from "bun:test";
import { isWheelNotch } from "./wheelGlide";

const pixels = (deltaY: number, wheelDeltaY?: number) => ({ deltaY, deltaMode: 0, wheelDeltaY });

describe("isWheelNotch", () => {
  test("a wheel's lines or pages are a notch", () => {
    expect(isWheelNotch({ deltaY: 3, deltaMode: 1 })).toBe(true);
    expect(isWheelNotch({ deltaY: -1, deltaMode: 2 })).toBe(true);
  });

  test("Chromium: a tick counts 120 in wheelDeltaY whatever its pixels", () => {
    // A slow notch on macOS, a fast one, and Windows' 100px.
    expect(isWheelNotch(pixels(4.000244140625, -120))).toBe(true);
    expect(isWheelNotch(pixels(-89.267578125, 240))).toBe(true);
    expect(isWheelNotch(pixels(100, -120))).toBe(true);
  });

  test("Chromium: a precise scroll's wheelDeltaY is three times its pixels", () => {
    expect(isWheelNotch(pixels(13, -39))).toBe(false);
    expect(isWheelNotch(pixels(2.5, -7))).toBe(false);
    // 40px is a precise 40px or a whole line: left to the engine.
    expect(isWheelNotch(pixels(40, -120))).toBe(false);
  });

  test("WebKit on macOS: a notch scrolls fixed-point lines times 40", () => {
    // 0.1 lines (a slow notch), an accelerated 0.535 lines, and about 2.5 lines down and up.
    expect(isWheelNotch(pixels(4.000244140625, -12))).toBe(true);
    expect(isWheelNotch(pixels(21.4019775390625, -64))).toBe(true);
    expect(isWheelNotch(pixels(100.006103515625, -300))).toBe(true);
    expect(isWheelNotch(pixels(-100.006103515625, 300))).toBe(true);
  });

  test("WebKit: a trackpad scrolls whole points", () => {
    expect(isWheelNotch(pixels(7, -21))).toBe(false);
    expect(isWheelNotch(pixels(-120, 360))).toBe(false);
    expect(isWheelNotch(pixels(2.5, -7))).toBe(false);
    expect(isWheelNotch(pixels(0.75, -2))).toBe(false);
    // 25/64px and 85/64px sit on the fixed-point grid too: a fraction of a point is a trackpad's.
    expect(isWheelNotch(pixels(0.390625, -1))).toBe(false);
    expect(isWheelNotch(pixels(-1.328125, 3))).toBe(false);
    // Any other fraction is not a fixed-point line either.
    expect(isWheelNotch(pixels(6.3636, -19))).toBe(false);
  });

  test("no movement, or no legacy delta, is not a notch", () => {
    expect(isWheelNotch(pixels(0, 0))).toBe(false);
    expect(isWheelNotch(pixels(4.000244140625))).toBe(false);
    expect(isWheelNotch(pixels(4.000244140625, 0))).toBe(false);
  });
});
