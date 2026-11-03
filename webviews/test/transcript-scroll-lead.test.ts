import { describe, expect, test } from "bun:test";
import { geometryFromHeights } from "../src/agent-session/acpmux/conversationGeometry";
import { mergeRowRanges, scrollLeadRanges, visibleLayoutRange, type RowRange } from "../src/agent-session/acpmux/model";

const geometry = geometryFromHeights(new Float64Array(3000).fill(20));
const layout = { geometry, totalHeight: geometry.totalHeight };
const top = 30_000;
const height = 600;
const cap = 4 * height;
const covers = (ranges: RowRange[], offset: number) =>
  ranges.some(({ first, last }) => geometry.topAt(first) <= offset && geometry.topAt(last) >= offset + height);
const count = (ranges: RowRange[]) => ranges.reduce((sum, range) => sum + range.last - range.first, 0);

describe("transcript scroll lead", () => {
  test("large skips mount fewer rows while covering the current and both predicted views", () => {
    for (const direction of [-1, 1]) {
      const delta = direction * 6 * height;
      const ranges = scrollLeadRanges(layout, top, delta, height, 2, cap);
      const predictions = [1, 2].map((step) => visibleLayoutRange(layout, top + delta * step - height / 2, 2 * height));
      const previous = mergeRowRanges([
        visibleLayoutRange(layout, direction < 0 ? top - cap : top, height + cap),
        ...predictions,
      ]);
      expect(count(ranges)).toBeLessThan(count(previous));
      for (const offset of [top, top + delta, top + 2 * delta]) expect(covers(ranges, offset)).toBe(true);
      // The first frame after a stop/slowdown/reversal can still use the previous mount window.
      for (const offset of [top - height, top - height / 2, top + height / 2, top + height])
        expect(covers(ranges, offset)).toBe(true);
    }
  });

  test("ordinary wheel and uneven drag steps keep the contiguous lead through the cap", () => {
    for (const delta of [-cap, -3 * height, -40, 0, 40, 3 * height, cap]) {
      const lead = Math.min(Math.abs(delta) * 2, cap);
      const ranges = scrollLeadRanges(layout, top, delta, height, 2, cap);
      const immediate = visibleLayoutRange(layout, delta < 0 ? top - lead : top, height + lead);
      expect(ranges.some(({ first, last }) => first <= immediate.first && last >= immediate.last)).toBe(true);
    }
  });
});
