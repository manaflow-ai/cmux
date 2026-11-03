import { describe, expect, test } from "bun:test";
import {
  layoutGeometry,
  placedFromEstimate,
  placedWithOrigin,
  placeRows,
  placeRowsIndexed,
  visibleLayoutRange,
  withOrigin,
  type ConversationLayout,
  type PlacedLayout,
} from "./model";
import {
  MARK_FOOTER,
  MARK_FOOTER_ROW,
  MARK_FOOTER_SLOT,
  MARK_INDICATOR,
  MARK_MESSAGE,
  MARK_PROMPT,
  MARK_STATUS,
  MARK_STEP,
} from "./transcriptGrid";

// Equivalence of the gap-aware index with base's sequential `placeRows`: every top, height, the
// total, the tail gap and the rest band, for random rows with zero-height runs, every mark, own
// gaps, an origin, and the incremental passes App makes (an insert, a resize mid-list, a removal).

const MARKS = [
  0,
  MARK_PROMPT,
  MARK_MESSAGE,
  MARK_INDICATOR,
  MARK_FOOTER,
  MARK_STEP,
  MARK_FOOTER_ROW,
  MARK_FOOTER_SLOT,
  MARK_STATUS,
];
/// Float rounding of a tree's sums against a left-to-right pass: far under a device pixel.
const EPSILON = 1e-6;

function random(seed: number) {
  let state = seed >>> 0 || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4294967296;
  };
}

type Rows = { heights: number[]; marks: number[]; gaps: number[] };

function randomRows(next: () => number, count: number): Rows {
  const rows: Rows = { heights: [], marks: [], gaps: [] };
  for (let index = 0; index < count; index += 1) pushRow(rows, next);
  return rows;
}

function pushRow(rows: Rows, next: () => number, at = rows.heights.length) {
  const roll = next();
  // A third draw nothing, some in long runs; the rest are fractional, as drawn text is.
  const height = roll < 0.33 ? 0 : roll < 0.4 ? 22.75 : Math.round(next() * 4000) / 16;
  rows.heights.splice(at, 0, height);
  rows.marks.splice(at, 0, MARKS[Math.floor(next() * MARKS.length)]!);
  rows.gaps.splice(at, 0, Math.floor(next() * 4) * 8);
}

function estimateOf(rows: Rows, withMarks = true): ConversationLayout {
  const count = rows.heights.length;
  return {
    tops: new Float64Array(count),
    heights: Float64Array.from(rows.heights),
    totalHeight: 0,
    gaps: Float64Array.from(rows.gaps),
    ...(withMarks ? { marks: Uint8Array.from(rows.marks) } : { tailGap: 7, restBand: 3 }),
    scale: 1,
  };
}

function expectSame(indexed: PlacedLayout, base: ConversationLayout) {
  const geometry = indexed.geometry;
  expect(geometry.count).toBe(base.heights.length);
  for (let index = 0; index < base.heights.length; index += 1) {
    expect(geometry.heightAt(index)).toBe(base.heights[index]!);
    expect(Math.abs(geometry.topAt(index) - base.tops[index]!)).toBeLessThan(EPSILON);
  }
  geometry.scan(0, geometry.count, (index, top, height) => {
    expect(Math.abs(top - base.tops[index]!)).toBeLessThan(EPSILON);
    expect(height).toBe(base.heights[index]!);
  });
  expect(Math.abs(indexed.totalHeight - base.totalHeight)).toBeLessThan(EPSILON);
  expect(indexed.tailGap).toBe(base.tailGap);
  expect(indexed.restBand).toBe(base.restBand);
  expect(indexed.origin ?? 0).toBe(base.origin ?? 0);
  // The gap a row draws above itself (App's `gapBelow` of the row before it).
  for (let index = 1; index < base.heights.length; index += 1) {
    const gap = Math.max(0, base.tops[index]! - base.tops[index - 1]! - base.heights[index - 1]!);
    expect(Math.abs(geometry.gapAt(index) - gap)).toBeLessThan(EPSILON);
  }
  // Range queries read the same rows.
  for (let probe = -10; probe < base.totalHeight + 40; probe += Math.max(7, base.totalHeight / 97)) {
    expect(visibleLayoutRange(indexed, probe, 300)).toEqual(visibleLayoutRange(base, probe, 300));
  }
}

describe("placeRowsIndexed matches placeRows", () => {
  test("random rows: zero-height runs, every mark, own gaps and origins", () => {
    for (let seed = 1; seed <= 40; seed += 1) {
      const next = random(seed);
      const rows = randomRows(next, 1 + Math.floor(next() * 300));
      const drawn = rows.heights.map((height) => (next() < 0.5 ? undefined : next() < 0.2 ? 0 : height + 3.5));
      const heightAt = (index: number) => drawn[index];
      for (const withMarks of [true, false])
        for (const origin of [0, 1234.5]) {
          const estimate = estimateOf(rows, withMarks);
          expectSame(
            placeRowsIndexed(estimate, heightAt, undefined, origin),
            placeRows(estimate, heightAt, undefined, origin),
          );
        }
    }
  });

  test("the gap rules: a drawn row's gap comes from the nearest drawn row above it", () => {
    // A prompt, hidden rows, a message: the turn gap, not a gap from the hidden rows' marks.
    const rows: Rows = {
      heights: [40, 0, 0, 80, 0, 32, 22, 22, 0],
      marks: [
        MARK_PROMPT,
        MARK_STEP,
        MARK_FOOTER,
        MARK_MESSAGE,
        MARK_STEP,
        MARK_FOOTER_ROW,
        MARK_STEP,
        MARK_STEP,
        MARK_FOOTER,
      ],
      gaps: [0, 0, 0, 0, 0, 0, 0, 0, 0],
    };
    const estimate = estimateOf(rows);
    const indexed = placeRowsIndexed(estimate, () => undefined);
    expectSame(
      indexed,
      placeRows(estimate, () => undefined),
    );
    // A trailing empty footer: the tail takes the block gap and the rest band.
    expect(indexed.restBand).toBeGreaterThan(0);
    // A row that starts drawing changes the gap of the next drawn row.
    const grown = (index: number) => (index === 4 ? 22 : undefined);
    expectSame(placeRowsIndexed(estimate, grown), placeRows(estimate, grown));
  });

  test("the tail: no drawn row, one drawn row, a footer after it", () => {
    for (const rows of [
      { heights: [0, 0], marks: [MARK_FOOTER, MARK_FOOTER], gaps: [0, 0] },
      { heights: [30], marks: [MARK_INDICATOR], gaps: [0] },
      { heights: [30, 10, 0], marks: [MARK_PROMPT, MARK_INDICATOR, MARK_FOOTER], gaps: [0, 0, 0] },
      { heights: [], marks: [], gaps: [] },
    ]) {
      const estimate = estimateOf(rows);
      expectSame(
        placeRowsIndexed(estimate, () => undefined),
        placeRows(estimate, () => undefined),
      );
    }
  });

  test("incremental passes: appends, an insert, resizes mid-list and a removal", () => {
    for (let seed = 100; seed < 112; seed += 1) {
      const next = random(seed);
      const rows = randomRows(next, 200 + Math.floor(next() * 200));
      let drawn = rows.heights.map((height) => height);
      const heightAt = (index: number) => drawn[index];
      let estimate = estimateOf(rows);
      let base = placeRows(estimate, heightAt, undefined, 64);
      let indexed = placeRowsIndexed(estimate, heightAt, undefined, 64);
      expectSame(indexed, base);
      for (let pass = 0; pass < 30; pass += 1) {
        const kind = pass % 4;
        let kept: number;
        let from: number | undefined;
        let changed: number[] | undefined;
        if (kind === 0) {
          // A token: the last row grows, or a row arrives.
          if (next() < 0.5) pushRow(rows, next);
          kept = rows.heights.length - 1;
          drawn = [...drawn.slice(0, kept), ...rows.heights.slice(kept)];
        } else if (kind === 1) {
          // An insert mid-list (a page in, a row placed between two).
          const at = Math.floor(next() * rows.heights.length);
          pushRow(rows, next, at);
          drawn.splice(at, 0, rows.heights[at]!);
          kept = at;
        } else if (kind === 2) {
          // Rows mid-list draw at new heights (one starts or stops drawing).
          changed = [];
          for (let count = 0; count < 3; count += 1) {
            const at = Math.floor(next() * rows.heights.length);
            drawn[at] = next() < 0.3 ? 0 : Math.round(next() * 3000) / 16;
            changed.push(at);
          }
          kept = Math.min(...changed);
          from = rows.heights.length;
        } else {
          // A removal mid-list.
          const at = Math.floor(next() * rows.heights.length);
          for (const list of [rows.heights, rows.marks, rows.gaps, drawn]) list.splice(at, 1);
          kept = at;
        }
        estimate = estimateOf(rows);
        base = placeRows(estimate, heightAt, { layout: base, kept }, 64);
        indexed = placeRowsIndexed(estimate, heightAt, { layout: indexed, kept, from, changed }, 64);
        expectSame(indexed, base);
      }
    }
  });

  test("another origin places every row again, as placeRows does", () => {
    const next = random(7);
    const rows = randomRows(next, 150);
    const estimate = estimateOf(rows);
    const heightAt = () => undefined;
    const first = placeRowsIndexed(estimate, heightAt, undefined, 10);
    const base = placeRows(estimate, heightAt, { layout: placeRows(estimate, heightAt, undefined, 10), kept: 100 }, 50);
    expectSame(placeRowsIndexed(estimate, heightAt, { layout: first, kept: 100 }, 50), base);
  });

  test("an origin moves every top in O(1), as withOrigin does", () => {
    const next = random(9);
    const rows = randomRows(next, 180);
    const estimate = estimateOf(rows);
    const base = placeRows(estimate, () => undefined, undefined, 20);
    const indexed = placeRowsIndexed(estimate, () => undefined, undefined, 20);
    expectSame(placedWithOrigin(indexed, 500), withOrigin(base, 500));
    expectSame(placedWithOrigin(indexed, 0), withOrigin(base, 0));
    // An unplaced estimate (no row drawn yet) reads the same as the estimate's arrays.
    expectSame(placedWithOrigin(placedFromEstimate(base, 20), 77), withOrigin(base, 77));
  });

  test("a resize reads only the changed rows: two reads at 9,000 rows and at 90,000", () => {
    for (const count of [9_000, 90_000]) {
      const next = random(count);
      const rows = randomRows(next, count);
      const estimate = estimateOf(rows);
      const placed = placeRowsIndexed(estimate, () => undefined);
      let reads = 0;
      const heightAt = (index: number) => {
        reads += 1;
        return index === 10 || index === count - 20 ? 99 : undefined;
      };
      const after = placeRowsIndexed(estimate, heightAt, {
        layout: placed,
        kept: 10,
        from: count,
        changed: [10, count - 20],
      });
      expect(reads).toBe(2);
      expect(after.geometry.heightAt(10)).toBe(99);
      expect(placed.geometry.heightAt(10)).toBe(rows.heights[10]!);
      expectSame(
        after,
        placeRows(estimate, (index) => (index === 10 || index === count - 20 ? 99 : undefined)),
      );
    }
  });

  test("a streamed token reads one row and keeps the old snapshot", () => {
    const next = random(3);
    const rows = randomRows(next, 5_000);
    const estimate = estimateOf(rows);
    const placed = placeRowsIndexed(estimate, () => undefined);
    const before = layoutGeometry(placed).topAt(4_999);
    rows.heights[4_999] = 400;
    let reads = 0;
    const grown = placeRowsIndexed(estimateOf(rows), () => ((reads += 1), undefined), { layout: placed, kept: 4_999 });
    expect(reads).toBe(1);
    expect(grown.geometry.heightAt(4_999)).toBe(400);
    expect(layoutGeometry(placed).topAt(4_999)).toBe(before);
  });
});
