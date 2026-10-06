import { describe, expect, test } from "bun:test";
import { resolveUiOverlayPosition } from "../src/ui/anchor";

describe("anchored overlay placement", () => {
  const viewport = { width: 800, height: 600 };

  test("keeps the leading edge on the trigger with the shared gap", () => {
    const placement = resolveUiOverlayPosition(
      { left: 120, top: 220, right: 180, bottom: 252 },
      { width: 240, height: 120 },
      viewport,
      { side: "above", align: "start" },
    );
    expect(placement.side).toBe("above");
    expect(Math.abs(placement.left - 120)).toBeLessThanOrEqual(2);
    expect(Math.abs(placement.top - (220 - 6 - 120))).toBeLessThanOrEqual(2);
  });

  test("flips below when the requested side has less room", () => {
    const placement = resolveUiOverlayPosition(
      { left: 300, top: 40, right: 360, bottom: 72 },
      { width: 180, height: 220 },
      viewport,
      { side: "above", align: "start" },
    );
    expect(placement.side).toBe("below");
    expect(Math.abs(placement.top - (72 + 6))).toBeLessThanOrEqual(2);
  });

  test("clamps a wide menu without losing its requested edge where possible", () => {
    const placement = resolveUiOverlayPosition(
      { left: 780, top: 260, right: 800, bottom: 292 },
      { width: 260, height: 100 },
      viewport,
      { side: "below", align: "start" },
    );
    expect(placement.left).toBe(532);
    expect(placement.maxHeight).toBeGreaterThan(0);
  });

  test("mirrors leading alignment for right-to-left pages", () => {
    const placement = resolveUiOverlayPosition(
      { left: 420, top: 220, right: 500, bottom: 252 },
      { width: 160, height: 100 },
      viewport,
      { side: "below", align: "start", direction: "rtl" },
    );
    expect(placement.left).toBe(340);
  });
});
