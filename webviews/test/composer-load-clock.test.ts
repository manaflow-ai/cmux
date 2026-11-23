import { expect, test } from "bun:test";
import { clocksAgree, streamEndOnPageClock } from "../bench/composer-load";

// An iframe made 500 ms after the page, whose timeOrigin the wall clock pinned 3 ms off (a wall-clock step, or the
// 1 ms grain twice): its epoch and the page's epoch disagree by 3 ms, though both documents' performance.now() run on
// one monotonic clock. The load receipt's stream must still be placed exactly on the page's clock.
const pageOrigin = 1_763_000_000_000.25;
const frame = { offset_ms: -500, origin_ms: pageOrigin + 500 + 3, read_ms: 0.02 };

test("a load document's stream end lands on the page clock whatever its timeOrigin's wall-clock skew", () => {
  // Started at the frame's now = 100 (page now 600), progressed for 2,000 ms: page now 2,600.
  const receipt = { started_epoch_ms: frame.origin_ms + 100, elapsedMs: 2000 };
  expect(streamEndOnPageClock(receipt, frame)).toBeCloseTo(2600, 6);
  // The same frame read again after the keys: one clock, a valid run.
  const clocks = { page_origin_ms: pageOrigin, surfaces: [frame] };
  expect(clocksAgree(clocks, { page_origin_ms: pageOrigin, surfaces: [{ ...frame, read_ms: 0.05 }] })).toBe(true);
  // The old epoch comparison read this skew as an invalid run: 3 ms is past its 2 ms bound.
  expect(Math.abs(frame.origin_ms - 500 - pageOrigin)).toBeGreaterThanOrEqual(2);
});

test("clocks that moved apart, or a slow read, or a missing document, invalidate the run", () => {
  const before = { page_origin_ms: pageOrigin, surfaces: [frame] };
  expect(clocksAgree(before, { page_origin_ms: pageOrigin, surfaces: [{ ...frame, offset_ms: -505 }] })).toBe(false);
  expect(clocksAgree(before, { page_origin_ms: pageOrigin, surfaces: [{ ...frame, read_ms: 3 }] })).toBe(false);
  expect(clocksAgree(before, { page_origin_ms: pageOrigin, surfaces: [{ ...frame, offset_ms: Number.NaN }] })).toBe(
    false,
  );
  expect(clocksAgree(before, { page_origin_ms: pageOrigin, surfaces: [] })).toBe(false);
  expect(Number.isNaN(streamEndOnPageClock({ started_epoch_ms: 0, elapsedMs: 0 }, undefined))).toBe(true);
});
