// Elapsed labels on the page clock: seconds under a minute, whole minutes after,
// re-rendered each second and then each minute.
import { expect, test } from "bun:test";
import { ELAPSED_MINUTE_MS, elapsedGranularity, shownElapsed } from "../src/ui/useElapsedNow";

test("a running label shows its seconds under a minute and whole minutes after", () => {
  expect(shownElapsed(-5_000)).toBe(0);
  expect(shownElapsed(0)).toBe(0);
  expect(shownElapsed(59_999)).toBe(59_999);
  expect(shownElapsed(ELAPSED_MINUTE_MS)).toBe(60_000);
  expect(shownElapsed(119_999)).toBe(60_000);
  expect(shownElapsed(354_000)).toBe(300_000);
  expect(shownElapsed(3_725_000)).toBe(3_720_000);
});

test("a label ticks each second under a minute and each minute after", () => {
  expect(elapsedGranularity(undefined, 600_000)).toBe("second");
  expect(elapsedGranularity(30_500, 90_000)).toBe("second");
  expect(elapsedGranularity(30_500, 91_000)).toBe("minute");
  expect(elapsedGranularity(0, 60_000)).toBe("minute");
  // A start in the future (another computer's clock) stays on seconds.
  expect(elapsedGranularity(200_000, 120_000)).toBe("second");
});
