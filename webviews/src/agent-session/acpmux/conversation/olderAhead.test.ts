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
