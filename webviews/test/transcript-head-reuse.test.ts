// l10n-allow-file: geometry fixtures, not shipped UI.
// A page of older history above the rows: the estimate (model.ts layoutConversation) and the
// placement (placeRowsIndexed) keep every row after it in its index (placedHeightIndex.ts
// replaceHead) and place only the page, and they say what a layout of every row says.
import { describe, expect, test } from "bun:test";
import {
  keptAfterHead,
  layoutConversation,
  placeRowsIndexed,
  type AcpmuxRow,
  type ConversationLayout,
  type PreparedRow,
  type RowHeights,
} from "../src/agent-session/acpmux/model";
import { PlacedHeightIndex } from "../src/agent-session/acpmux/placedHeightIndex";
import { noteKeptSuffix } from "../src/agent-session/acpmux/conversation/rowsDelta";
import { latestMessageIndex } from "../src/agent-session/acpmux/conversation/messagePlacement";

const turn = (prefix: string, at: number): AcpmuxRow[] => [
  { id: `${prefix}u${at}`, kind: "user", text: `Question ${prefix}${at}: what changed?`, version: 1, at },
  {
    id: `${prefix}a${at}`,
    kind: "assistant",
    text: `Answer ${prefix}${at}: ${"the lane wraps at a narrow width ".repeat(1 + (at % 4))}`,
    version: 1,
    at,
  },
];
const chat = (prefix: string, turns: number) => Array.from({ length: turns }, (_, at) => turn(prefix, at)).flat();

describe("PlacedHeightIndex.replaceHead", () => {
  const between = (a: number, b: number) => (a === b ? 4 : 8);
  const rows = (count: number, seed: number) => ({
    heights: Array.from({ length: count }, (_, at) => ((at * 7 + seed) % 5 === 0 ? 0 : 10 + ((at + seed) % 9))),
    marks: Array.from({ length: count }, (_, at) => (at + seed) % 3),
  });
  const same = (a: PlacedHeightIndex, b: PlacedHeightIndex) => {
    expect(a.count).toBe(b.count);
    expect(a.totalHeight).toBeCloseTo(b.totalHeight, 6);
    expect(a.lastMarks).toEqual(b.lastMarks);
    for (let at = 0; at < a.count; at += 1) {
      expect(a.heightAt(at)).toBe(b.heightAt(at));
      expect(a.markAt(at)).toBe(b.markAt(at));
      expect(a.topAt(at)).toBeCloseTo(b.topAt(at), 6);
      expect(a.gapAt(at)).toBeCloseTo(b.gapAt(at), 6);
    }
    for (const target of [-5, 0, 3, 100, a.totalHeight / 2, a.totalHeight - 1, a.totalHeight + 5])
      expect(a.upperBoundTop(target)).toBe(b.upperBoundTop(target));
  };

  test("pages above, rows taken from the head, and edits after them place as an index built whole", () => {
    let { heights, marks } = rows(300, 1);
    let index = PlacedHeightIndex.fromRows(heights, marks, undefined, { between });
    for (let step = 0; step < 40; step += 1) {
      const removed = step % 3 === 2 ? 1 + (step % 4) : step % 5;
      const page = rows(step % 4 === 0 ? 130 : 1 + (step % 7), step);
      index = index.replaceHead(removed, page.heights, page.marks);
      heights = [...page.heights, ...heights.slice(removed)];
      marks = [...page.marks, ...marks.slice(removed)];
      if (step % 2) {
        const at = (step * 13) % heights.length;
        heights[at] = 33;
        index = index.update(at, 33);
      }
      if (step % 5 === 4) {
        const tail = rows(3, step);
        index = index.splice(heights.length - 2, tail.heights, tail.marks);
        heights = [...heights.slice(0, -2), ...tail.heights];
        marks = [...marks.slice(0, -2), ...tail.marks];
      }
      same(index, PlacedHeightIndex.fromRows(heights, marks, undefined, { between }));
    }
  });
});

describe("a page above the rows", () => {
  const width = 720;
  /// The estimate and its arrays, as plain values (the tops up to float rounding of the sums).
  const read = (layout: ConversationLayout) => ({
    heights: [...layout.heights],
    marks: [...layout.marks!],
    gaps: [...layout.gaps!].map((gap) => Math.round(gap * 1e6) / 1e6),
    tops: [...layout.tops].map((top) => Math.round(top * 1e6) / 1e6),
    totalHeight: Math.round(layout.totalHeight * 1e6) / 1e6,
    tailGap: layout.tailGap,
    restBand: layout.restBand,
  });

  test("the estimate keeps the rows after it and estimates the page, as a layout of every row does", () => {
    const cache = new Map<string, PreparedRow>();
    const known: RowHeights = new WeakMap();
    let rows: AcpmuxRow[] = chat("r", 400);
    let layout = layoutConversation(rows, width, cache, undefined, known);
    for (let page = 0; page < 6; page += 1) {
      const before = rows;
      rows = page % 3 === 2 ? before.slice(2) : [...turn(`p${page}-`, page), ...before];
      noteKeptSuffix(rows, before, page % 3 === 2 ? rows.length : before.length);
      const next = layoutConversation(rows, width, cache, undefined, known, { rows: before, layout });
      expect(keptAfterHead(next)?.over).toBe(layout);
      const whole = layoutConversation(rows, width, new Map(), undefined, new WeakMap());
      expect(read(next)).toEqual(read(whole));
      expect(latestMessageIndex(next)).toBe(latestMessageIndex(whole));
      layout = next;
    }
  });

  test("the placement keeps the rows after it in its index and places the page", () => {
    const cache = new Map<string, PreparedRow>();
    const known: RowHeights = new WeakMap();
    let rows: AcpmuxRow[] = chat("r", 300);
    let estimate = layoutConversation(rows, width, cache, undefined, known);
    // Some rows drawn at their own heights, as mounted rows report them.
    const drawn = new Map<string, number>(rows.slice(-40).map((row, at) => [row.id, 30 + (at % 7)]));
    const heightAt = (list: readonly AcpmuxRow[]) => (index: number) => drawn.get(list[index]!.id);
    let placed = placeRowsIndexed(estimate, heightAt(rows));
    for (let page = 0; page < 4; page += 1) {
      const before = rows;
      rows = [...turn(`p${page}-`, page), ...before];
      noteKeptSuffix(rows, before, before.length);
      const next = layoutConversation(rows, width, cache, undefined, known, { rows: before, layout: estimate });
      const head = keptAfterHead(next)!;
      expect(head.over).toBe(estimate);
      const kept = placeRowsIndexed(next, heightAt(rows), {
        layout: placed,
        kept: head.added,
        from: rows.length,
        changed: [],
        head,
      });
      const whole = placeRowsIndexed(next, heightAt(rows));
      expect(kept.geometry.count).toBe(whole.geometry.count);
      expect(kept.totalHeight).toBeCloseTo(whole.totalHeight, 6);
      expect(kept.tailGap).toBe(whole.tailGap);
      for (let at = 0; at < rows.length; at += 1) {
        expect(kept.geometry.heightAt(at)).toBe(whole.geometry.heightAt(at));
        expect(kept.geometry.topAt(at)).toBeCloseTo(whole.geometry.topAt(at), 6);
      }
      // Over a placement of another estimate (here the new one's own), the head is not kept: every
      // row is placed again, with the same result.
      const over = placeRowsIndexed(next, heightAt(rows), { layout: whole, kept: head.added, changed: [], head });
      expect(over.totalHeight).toBeCloseTo(whole.totalHeight, 6);
      expect(over.geometry.topAt(rows.length - 1)).toBeCloseTo(whole.geometry.topAt(rows.length - 1), 6);
      estimate = next;
      placed = kept;
    }
  });
});
