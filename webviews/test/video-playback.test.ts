// The in-app video viewer's rules (chips/videoPlaybackModel.ts). Leo, 2026-11-22: "is there a way we
// can just watch the .mp4s in the app? i want that. in-app video player."
import { describe, expect, test } from "bun:test";
import {
  clockTime,
  followerSeek,
  nextRate,
  pairCaptions,
  playbackKey,
  steppedTime,
} from "../src/agent-session/acpmux/chips/videoPlaybackModel";
import { videoPair } from "../src/agent-session/acpmux/conversation/inlineMedia";

describe("video viewer", () => {
  test("speed steps through 0.5x, 1x and 2x and holds at the ends", () => {
    expect(nextRate(1, 1)).toBe(2);
    expect(nextRate(2, 1)).toBe(2);
    expect(nextRate(1, -1)).toBe(0.5);
    expect(nextRate(0.5, -1)).toBe(0.5);
    expect(nextRate(1.5, -1)).toBe(1);
  });
  test("a frame step moves one 30 fps frame and stays inside the clip", () => {
    expect(steppedTime(1, 1, 10)).toBeCloseTo(1 + 1 / 30);
    expect(steppedTime(0.01, -1, 10)).toBe(0);
    expect(steppedTime(9.99, 1, 10)).toBe(10);
    expect(steppedTime(1, 1, Number.NaN)).toBeCloseTo(1 + 1 / 30);
  });
  test("the second clip of a pair follows the first past the drift, and holds its last frame", () => {
    expect(followerSeek(2, 2.01, 10)).toBeUndefined();
    expect(followerSeek(2, 2.5, 10)).toBe(2);
    expect(followerSeek(12, 9, 10)).toBe(10);
    expect(followerSeek(12, 10, 10)).toBeUndefined();
  });
  test("keys: space and K play, comma and period step, brackets change speed, L loops; chords are not ours", () => {
    expect(playbackKey({ key: " " })).toEqual({ kind: "toggle" });
    expect(playbackKey({ key: "." })).toEqual({ kind: "step", direction: 1 });
    expect(playbackKey({ key: "[" })).toEqual({ kind: "rate", direction: -1 });
    expect(playbackKey({ key: "L" })).toEqual({ kind: "loop" });
    expect(playbackKey({ key: "l", metaKey: true })).toBeUndefined();
    expect(playbackKey({ key: "x" })).toBeUndefined();
  });
  test("the clock shows tenths", () => {
    expect(clockTime(0)).toBe("0:00.0");
    expect(clockTime(61.27)).toBe("1:01.2");
  });
  test("a pair is captioned by its labels, else Before and After when the names say so", () => {
    const names = { before: "Before", after: "After" };
    expect(
      pairCaptions(
        [
          { src: "/a/x-before.mp4", alt: "" },
          { src: "/a/x-after.mp4", alt: "" },
        ],
        names,
      ),
    ).toEqual(["Before", "After"]);
    expect(
      pairCaptions(
        [
          { src: "/a/one.mp4", alt: "" },
          { src: "/a/two.mp4", alt: "" },
        ],
        names,
      ),
    ).toEqual(["one.mp4", "two.mp4"]);
    expect(
      pairCaptions(
        [
          { src: "/a/x.mp4", alt: "", label: "Old" },
          { src: "/a/y.mp4", alt: "New" },
        ],
        names,
      ),
    ).toEqual(["Old", "New"]);
  });
  test("only two videos make a compare pair", () => {
    const v = (src: string) => ({ src, alt: "" });
    expect(videoPair([v("https://x.test/a.mp4"), v("/tmp/b.mov")])).toBeDefined();
    expect(videoPair([v("/tmp/a.png"), v("/tmp/b.mov")])).toBeUndefined();
    expect(videoPair([v("/tmp/a.mp4"), v("/tmp/b.mp4"), v("/tmp/c.mp4")])).toBeUndefined();
  });
});
