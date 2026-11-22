import { describe, expect, test } from "bun:test";
import { marqueeKeyframes, marqueeTiming, MOTION_MARQUEE, titleFade } from "./titleFade";

describe("title fade (TitleFadeGeometry port)", () => {
  test("a title that fits is not faded and does not scroll", () => {
    expect(titleFade({ textWidth: 80, span: 100, visibleWidth: 100, trailingPadding: 0, fadeWidth: 20 })).toEqual({
      truncated: false,
      fadeStart: 80,
      fadeEnd: 100,
      marqueeTravel: 0,
    });
  });
  test("a clipped title fades over its last fadeWidth and scrolls its end to the fade's start", () => {
    const fade = titleFade({ textWidth: 230.2, span: 100, visibleWidth: 100, trailingPadding: 0, fadeWidth: 20 });
    expect(fade).toEqual({ truncated: true, fadeStart: 80, fadeEnd: 100, marqueeTravel: 151 });
  });
  test("the fade is at most half of a short span", () => {
    expect(titleFade({ textWidth: 90, span: 30, visibleWidth: 30, trailingPadding: 0, fadeWidth: 20 }).fadeStart).toBe(
      15,
    );
  });
});

describe("marquee timing (MotionMarquee port)", () => {
  test("reading pace, shortest scroll, hold and the move spring's return", () => {
    const timing = marqueeTiming(120, false)!;
    expect(timing.delayMs).toBe(MOTION_MARQUEE.delayMs);
    expect(timing.scrollMs).toBe(3000);
    expect(timing.holdMs).toBe(1200);
    expect(timing.backMs).toBeGreaterThan(100);
    expect(timing.backMs).toBeLessThan(200);
    expect(marqueeTiming(4, false)!.scrollMs).toBe(MOTION_MARQUEE.minimumScrollMs);
  });
  test("no marquee under Reduce Motion or for a pixel of travel", () => {
    expect(marqueeTiming(120, true)).toBeNull();
    expect(marqueeTiming(1, false)).toBeNull();
  });
  test("keyframes scroll, hold and return", () => {
    const { keyframes, duration } = marqueeKeyframes(40, { delayMs: 600, scrollMs: 1000, holdMs: 1000, backMs: 200 });
    expect(duration).toBe(2200);
    expect(keyframes.map((frame) => [frame.offset, frame.translate])).toEqual([
      [0, "0px 0"],
      [1000 / 2200, "-40px 0"],
      [2000 / 2200, "-40px 0"],
      [1, "0px 0"],
    ]);
  });
});
