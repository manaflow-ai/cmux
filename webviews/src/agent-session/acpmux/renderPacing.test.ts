import { describe, expect, test } from "bun:test";
import { AdaptiveRenderRate } from "./renderPacing";

const DISPLAY = 1000 / 120;
/// `count` frame intervals at 120 Hz where a share `late` of them take two slots.
const scroll = (count: number, late: number) =>
  Array.from({ length: count }, (_, index) => (index < Math.round(count * late) ? 2 * DISPLAY : DISPLAY));

describe("AdaptiveRenderRate", () => {
  test("a scroll that misses a fifth of its 120 Hz slots stays at full rate (100 fps beats the cap's 60)", () => {
    const policy = new AdaptiveRenderRate();
    expect(policy.record(scroll(120, 0.2), DISPLAY, 1_000)).toBeUndefined();
    expect(policy.record(scroll(120, 0.6), DISPLAY, 2_000)).toBeUndefined();
    expect(policy.isFullRate).toBe(true);
  });

  test("a scroll that already draws at about the cap's rate drops to it", () => {
    const policy = new AdaptiveRenderRate();
    expect(policy.record(scroll(120, 1), DISPLAY, 1_000)).toBe(false);
    expect(policy.isFullRate).toBe(false);
  });

  test("a send's own motion never caps the rate", () => {
    const policy = new AdaptiveRenderRate();
    policy.sent(1_000);
    expect(policy.record(scroll(120, 1), DISPLAY, 2_200)).toBeUndefined();
    expect(policy.isFullRate).toBe(true);
    // A reader's heavy scroll well after the send still does.
    expect(policy.record(scroll(120, 1), DISPLAY, 10_000)).toBe(false);
  });

  test("the cap lifts after its backoff, which doubles at most to 40 s", () => {
    const policy = new AdaptiveRenderRate();
    expect(policy.record(scroll(120, 1), DISPLAY, 0)).toBe(false);
    const capped = Array.from({ length: 60 }, () => 2 * DISPLAY);
    expect(policy.record(capped, DISPLAY, 5_000)).toBeUndefined();
    expect(policy.record(capped, DISPLAY, 10_000)).toBe(true);
    let now = 10_000;
    for (let round = 0; round < 6; round += 1) {
      now += 1;
      expect(policy.record(scroll(120, 1), DISPLAY, now)).toBe(false);
      now += AdaptiveRenderRate.maximumBackoff;
      expect(policy.record(capped, DISPLAY, now)).toBe(true);
    }
  });

  test("a 60 Hz display has no cap to drop to", () => {
    const policy = new AdaptiveRenderRate();
    expect(policy.record(scroll(120, 1), 1000 / 60, 0)).toBeUndefined();
  });
});
