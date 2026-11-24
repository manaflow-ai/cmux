import { expect, test } from "bun:test";
import { OlderAhead } from "./olderAhead";

test("rising: only while the reader scrolls up, not at rest, going down, or after a pause", () => {
  const ahead = new OlderAhead();
  expect(ahead.rising(0)).toBe(false);
  ahead.scrolled(5000, 1000);
  expect(ahead.rising(1000)).toBe(false);
  ahead.scrolled(4900, 1016);
  expect(ahead.rising(1016)).toBe(true);
  expect(ahead.rising(1016 + 151)).toBe(false);
  ahead.scrolled(5100, 1032);
  expect(ahead.rising(1032)).toBe(false);
  ahead.reset();
  expect(ahead.rising(1032)).toBe(false);
});

test("rising: a wheel up held at the loaded rows' top counts, though the view did not move", () => {
  const ahead = new OlderAhead();
  ahead.scrolled(0, 1000);
  ahead.scrolled(0, 1016);
  expect(ahead.rising(1016)).toBe(false);
  ahead.wheeledUp(1020);
  expect(ahead.rising(1030)).toBe(true);
  expect(ahead.rising(1020 + 151)).toBe(false);
  ahead.wheeledUp(1200);
  ahead.reset();
  expect(ahead.rising(1200)).toBe(false);
});

test("ahead: a scroll's first event after a rest reads its frame's move as the speed", () => {
  const ahead = new OlderAhead();
  ahead.scrolled(100_000, 1000);
  // Still for a second, then a fling's first frame of 3,000 px: before, a speed of 0 (the floor only).
  ahead.scrolled(97_000, 2000);
  expect(ahead.rising(2000)).toBe(true);
  // 3,000 px a frame for two 400 ms reads: past the cap of 40 viewports.
  expect(ahead.ahead(4800, 800, 2000)).toBe(800 * 40);
  // A page landing above after a rest moves the view down: no speed.
  ahead.scrolled(99_000, 3000);
  expect(ahead.ahead(4800, 800, 3000)).toBe(4800);
});

test("ahead: an upward wheel's step is its speed before any scroll event", () => {
  const ahead = new OlderAhead();
  expect(ahead.ahead(4800, 800, 1000)).toBe(4800);
  // A trackpad step of 40 px: 2.4 px/ms, about 1,900 px ahead over two reads, under the floor.
  ahead.wheeledUp(1000, 40);
  expect(ahead.ahead(4800, 800, 1000)).toBe(4800);
  // A fling's 1,500 px step reaches the cap.
  ahead.wheeledUp(1016, 1500);
  expect(ahead.ahead(4800, 800, 1016)).toBe(800 * 40);
  // Past the scroll gap it no longer counts; nor after a reset.
  expect(ahead.ahead(4800, 800, 1016 + 151)).toBe(4800);
  ahead.wheeledUp(1200, 1500);
  ahead.reset();
  expect(ahead.ahead(4800, 800, 1200)).toBe(4800);
});
