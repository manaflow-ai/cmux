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

  test("a jump past the cap mounts its view alone, nothing between or beyond", () => {
    const delta = 8 * VIEW;
    const ranges = scrollLeadRanges(long, far, delta, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(at(8)).toBeLessThanOrEqual(VIEW + edges);
    expect(at(-8)).toBe(at(8));
    const mounted = (y: number) => ranges.some((range) => range.first <= rowAt(y) && rowAt(y) < range.last);
    expect(mounted(far)).toBe(true);
    expect(mounted(far + VIEW - 1)).toBe(true);
    expect(mounted(far + 2 * VIEW)).toBe(false);
    expect(mounted(far + delta)).toBe(false);
  });

  test("a jump mounts its view alone, however far", () => {
    expect(at(30)).toBeLessThanOrEqual(VIEW + edges);
    expect(at(300)).toBe(at(30));
    expect(at(-300)).toBe(at(30));
  });

  // Leo, 2026-11-16: "as in i scroll up and it loads the shit". The scroll-up bench's fling moves 1,500 to
  // 3,000 px a frame: inside the cap, each frame built a contiguous lead of up to 4 views, rows no frame drew.
  // The view the next frame reaches, with a view of margin either side, was three more views a frame,
  // built and measured in a commit that showed one; the next frame builds its own view.
  test("a fling of 1.5 to 4 views a frame, inside the cap, mounts its view only", () => {
    for (const views of [1.5, 2, 3, 4]) {
      const delta = -views * VIEW;
      const ranges = scrollLeadRanges(long, far, delta, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
      const mounted = (y: number) => ranges.some((range) => range.first <= rowAt(y) && rowAt(y) < range.last);
      expect(mounted(far)).toBe(true);
      expect(mounted(far + VIEW - 1)).toBe(true);
      expect(mounted(far + delta)).toBe(false);
      expect(mountedPx(delta)).toBeLessThanOrEqual(VIEW + edges);
    }
  });

  test("a scroll of a view a frame or less keeps its contiguous lead", () => {
    const [range] = scrollLeadRanges(long, far, -VIEW, VIEW, LEAD_STEPS, MAX_LEAD, TRAIL);
    expect(range!.first).toBeLessThanOrEqual(rowAt(far - 2 * VIEW));
    expect(range!.last).toBeGreaterThanOrEqual(rowAt(far + VIEW));
  });
});
