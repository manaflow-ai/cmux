// Which moments of an attached video the agent sees (videoFramePick.ts): each scene change found in
// the host's gray probes, even spacing between, as many frames as the video's length gives, and the
// frames within one video's byte budget. Leo, 2026-11-01: "i feel like cmux-next should give u
// better tools to deal with this kind of thing".
import { expect, test } from "bun:test";
import {
  change,
  evenTimes,
  fitFrames,
  frameCount,
  MAX_FRAMES,
  parseProbes,
  pickFrameTimes,
  type VideoProbe,
} from "../src/agent-session/acpmux/composer/videoFramePick";

const CELLS = 24 * 24;
const flat = (gray: number) => new Uint8Array(CELLS).fill(gray);
/// Probes two a second over `seconds`, gray `shade(t)` at each time `t` (seconds).
function probes(seconds: number, shade: (t: number) => number): VideoProbe[] {
  return Array.from({ length: seconds * 2 }, (_, index) => {
    const atMs = Math.round(((index + 0.5) * 1000) / 2);
    return { atMs, cells: flat(shade(atMs / 1000)) };
  });
}

test("the frame count grows with the video's length, between 8 and 16 past 8 s", () => {
  expect(frameCount(0)).toBe(0);
  expect(frameCount(3_000)).toBe(3);
  expect(frameCount(16_000)).toBe(8);
  expect(frameCount(24_000)).toBe(12);
  expect(frameCount(60_000)).toBe(16);
  expect(frameCount(3_600_000)).toBe(MAX_FRAMES);
});

test("without probes (an older host) the times are even", () => {
  expect(pickFrameTimes(16_000, [])).toEqual(evenTimes(16_000, 8).map((atMs) => ({ atMs, scene: false })));
  expect(evenTimes(16_000, 4)).toEqual([2000, 6000, 10_000, 14_000]);
});

test("each scene change gets a frame at its cut, marked, and the rest fill the gaps", () => {
  // Black, then white from 5 s, then gray from 11 s: two cuts.
  const shade = (t: number) => (t < 5 ? 0 : t < 11 ? 255 : 128);
  const picked = pickFrameTimes(16_000, probes(16, shade));
  expect(picked).toHaveLength(8);
  expect(picked.filter((pick) => pick.scene).map((pick) => pick.atMs)).toEqual([5250, 11_250]);
  // In order, all distinct, and none closer than a sixteenth of the video.
  const times = picked.map((pick) => pick.atMs);
  expect(times).toEqual([...times].sort((a, b) => a - b));
  for (let index = 1; index < times.length; index++)
    expect(times[index]! - times[index - 1]!).toBeGreaterThan(900);
  // The opening frame is there.
  expect(times[0]).toBe(250);
});

test("a still video (no cuts) is spread evenly", () => {
  const picked = pickFrameTimes(16_000, probes(16, () => 40));
  expect(picked.every((pick) => !pick.scene)).toBe(true);
  const times = picked.map((pick) => pick.atMs);
  const gaps = times.slice(1).map((at, index) => at - times[index]!);
  expect(Math.max(...gaps) - Math.min(...gaps)).toBeLessThanOrEqual(1001);
});

test("a flicker every probe never takes every frame: cuts keep their distance", () => {
  const picked = pickFrameTimes(16_000, probes(16, (t) => (Math.round(t * 2) % 2 ? 0 : 255)));
  const times = picked.map((pick) => pick.atMs);
  expect(times).toHaveLength(8);
  for (let index = 1; index < times.length; index++)
    expect(times[index]! - times[index - 1]!).toBeGreaterThanOrEqual(1000);
  // Seen throughout, not only its first seconds.
  expect(times.at(-1)! - times[0]!).toBeGreaterThan(11_000);
});

test("a cell counts as changed only past a step, and probes of other sizes do not compare", () => {
  expect(change(flat(10), flat(20))).toBe(0);
  expect(change(flat(10), flat(200))).toBe(1);
  expect(change(flat(10), new Uint8Array(4))).toBe(0);
});

test("frames over the byte budget thin out evenly and keep the first", () => {
  const frames = Array.from({ length: 16 }, (_, index) => ({ atMs: index * 1000, data: "x".repeat(100) }));
  const fitted = fitFrames(frames, 800);
  expect(fitted).toHaveLength(8);
  expect(fitted[0]!.atMs).toBe(0);
  const gaps = fitted.slice(1).map((frame, index) => frame.atMs - fitted[index]!.atMs);
  expect(Math.max(...gaps)).toBeLessThanOrEqual(3000);
  expect(fitFrames([{ atMs: 0, data: "x".repeat(10) }], 5)).toEqual([]);
});

test("the host's probes are checked: base64 cells of one size, a time each", () => {
  const cells = btoa(String.fromCharCode(...flat(7)));
  const parsed = parseProbes({
    probes: [
      { atMs: 250, cells },
      { atMs: 750, cells },
      { atMs: -1, cells },
      { atMs: 900, cells: btoa("abc") },
      { atMs: 1000, cells: "%%%" },
      "x",
    ],
  });
  expect(parsed?.map((probe) => probe.atMs)).toEqual([250, 750]);
  expect(parsed?.[0]!.cells[0]).toBe(7);
  expect(parseProbes({})).toBeUndefined();
});
