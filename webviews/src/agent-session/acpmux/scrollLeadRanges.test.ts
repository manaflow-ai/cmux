import { describe, expect, test } from "bun:test";
import { scrollLeadRanges, type ConversationLayout } from "./model";

// Leo, 2026-11-08: scrolling up and down quickly shows "hard cutoffs where there's no text at all
// for a brief second". The rows the reader just passed were unmounted the frame they left the view,
// so a reversal scrolled into bare background until the next commit drew them again.

/// `count` rows, each `pitch` px tall, back to back.
function rowsOf(count: number, pitch: number): ConversationLayout {
  const tops = new Float64Array(count);
  const heights = new Float64Array(count).fill(pitch);
  for (let at = 0; at < count; at += 1) tops[at] = at * pitch;
  return { tops, heights, totalHeight: count * pitch };
}

const VIEW = 500;
const PITCH = 50;
const LEAD_STEPS = 2;
const MAX_LEAD = VIEW * 4;
const TRAIL = VIEW;
const layout = rowsOf(1000, PITCH);
const top = 20_000;
const rowAt = (y: number) => Math.floor(y / PITCH);

describe("scrollLeadRanges trail", () => {
  test("a scroll down keeps the viewport it just passed mounted above the view", () => {
    const [range] = scrollLeadRanges(layout, top, 120, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(range!.first).toBeLessThanOrEqual(rowAt(top - TRAIL));
    // The lead below the view is unchanged.
    expect(range!.last).toBeGreaterThanOrEqual(rowAt(top + VIEW + 240));
  });

  test("a scroll up keeps the viewport it just passed mounted below the view", () => {
    const [range] = scrollLeadRanges(layout, top, -120, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(range!.last).toBeGreaterThanOrEqual(rowAt(top + VIEW + TRAIL));
    expect(range!.first).toBeLessThanOrEqual(rowAt(top - 240));
  });

  test("a view at rest mounts no trail (the deferred warm rows cover it)", () => {
    const [range] = scrollLeadRanges(layout, top, 0, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(range!.first).toBeGreaterThan(rowAt(top - TRAIL));
    expect(range!.last).toBeLessThan(rowAt(top + VIEW + TRAIL));
  });

  test("a fling past the lead cap builds no trail behind the jump", () => {
    const delta = MAX_LEAD;
    const ranges = scrollLeadRanges(layout, top, delta, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(ranges[0]!.first).toBeGreaterThan(rowAt(top - TRAIL));
  });
});
