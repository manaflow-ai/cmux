// A line opens or closes only for a deliberate click (Leo, 2026-11-06: "way too jittery/sensitive.
// and it's just slow").
import { describe, expect, test } from "bun:test";
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
