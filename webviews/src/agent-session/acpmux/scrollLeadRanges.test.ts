import { describe, expect, test } from "bun:test";
import { PREDICTED_JITTER, scrollLeadRanges, type ConversationLayout } from "./model";

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

// webui.transcript_scroll.fling.react_ms was 54 ms a frame on the perf cron, and more on a god
// session (60,000 rows): a fling past the lead cap built the capped lead (4 viewports) beside the
// views the next frames reach, rows no frame showed, and a longer chat only made each frame jump
// further. What a frame mounts is the view and the next frames' views, whatever the jump.
describe("scrollLeadRanges fast fling", () => {
  const long = rowsOf(200_000, PITCH);
  const far = 5_000_000;
  const mountedPx = (delta: number) =>
    scrollLeadRanges(long, far, delta, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL).reduce(
      (sum, range) => sum + (range.last - range.first) * PITCH,
      0,
    );
  const at = (vp: number) => mountedPx(vp * VIEW);
  /// A range's rows past its span: a jump's one row of overscan each side, and its edge rows.
  const edges = 4 * PITCH;

  test("a jump past the cap mounts the view and the next frame's view, nothing between or beyond", () => {
    const delta = 8 * VIEW;
    const ranges = scrollLeadRanges(long, far, delta, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    // The view and the next view with its margin (a view each side).
    expect(at(8)).toBeLessThanOrEqual(VIEW * 4 + 2 * edges);
    expect(at(-8)).toBe(at(8));
    const mounted = (y: number) => ranges.some((range) => range.first <= rowAt(y) && rowAt(y) < range.last);
    expect(mounted(far + 2 * VIEW)).toBe(false);
    expect(mounted(far + delta)).toBe(true);
    expect(mounted(far + delta + VIEW - 1)).toBe(true);
    expect(mounted(far + 2 * delta)).toBe(false);
  });

  test("a jump too far for its margin to hold mounts the view alone, however far", () => {
    // A view of margin is under PREDICTED_JITTER of a jump past 20 views.
    expect(VIEW).toBeLessThan(30 * VIEW * PREDICTED_JITTER);
    expect(at(30)).toBeLessThanOrEqual(VIEW + edges);
    expect(at(300)).toBe(at(30));
    expect(at(-300)).toBe(at(30));
  });

  test("a scrollbar drag within the cap keeps its contiguous lead", () => {
    const [range] = scrollLeadRanges(long, far, 3 * VIEW, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(range!.first).toBeLessThanOrEqual(rowAt(far));
    expect(range!.last).toBeGreaterThanOrEqual(rowAt(far + VIEW + MAX_LEAD));
  });
});
