// A line opens or closes only for a deliberate click, and a toggle that turns back midway retargets
// the fold in flight (Leo, 2026-11-06: "way too jittery/sensitive. and it's just slow").
import { describe, expect, test } from "bun:test";
import { turnMs } from "./fold";
import { CLICK_SLOP_PX, deliberateClick } from "./useAnchoredCollapse";

describe("deliberateClick", () => {
  const press = { x: 100, y: 50 };
  test("a keyboard click or a call with no event always toggles", () => {
    expect(deliberateClick(undefined, null, press)).toBe(true);
    expect(deliberateClick({ detail: 0, clientX: 0, clientY: 0 }, null, press)).toBe(true);
  });
  test("a click released where it pressed toggles", () => {
    expect(deliberateClick({ detail: 1, clientX: 102, clientY: 51 }, null, press)).toBe(true);
    expect(deliberateClick({ detail: 1, clientX: 100 + CLICK_SLOP_PX, clientY: 50 }, null, press)).toBe(true);
  });
  test("a drag past the slop does not", () => {
    expect(deliberateClick({ detail: 1, clientX: 100 + CLICK_SLOP_PX + 1, clientY: 50 }, null, press)).toBe(false);
    expect(deliberateClick({ detail: 1, clientX: 100, clientY: 70 }, null, press)).toBe(false);
  });
  test("a click with no press noted (a synthetic one) toggles", () => {
    expect(deliberateClick({ detail: 1, clientX: 300, clientY: 300 }, null, undefined)).toBe(true);
  });
});

describe("turnMs", () => {
  test("a fold that turns back plays only the share of its travel left", () => {
    // 40 of 200 px drawn when a close turns the open back: 40/200 of 180 ms, at least the quick step.
    expect(turnMs(180, 40, 0, 200)).toBe(80);
    expect(turnMs(180, 120, 0, 200)).toBeCloseTo(108);
    // An open that turns a close back at 150 of 200 px: 50 px left to go.
    expect(turnMs(180, 150, 200, 200)).toBe(80);
    expect(turnMs(180, 20, 200, 200)).toBeCloseTo(162);
  });
  test("never longer than a whole fold, never shorter than the quick step or the fold itself", () => {
    expect(turnMs(180, 0, 400, 200)).toBe(180);
    expect(turnMs(60, 10, 0, 200)).toBe(60);
    expect(turnMs(180, 0, 0, 0)).toBe(180);
  });
});
