import { describe, expect, test } from "bun:test";
import { PlacedHeightIndex } from "./placedHeightIndex";

function bruteTops(heights: readonly number[]): number[] {
  const tops: number[] = [];
  let top = 0;
  for (const height of heights) {
    tops.push(top);
    top += height;
  }
  return tops;
}

describe("PlacedHeightIndex", () => {
  test("matches full prefix geometry across block boundaries", () => {
    const heights = Array.from({ length: 192 }, (_, index) => (index * 7) % 23);
    const index = PlacedHeightIndex.fromHeights(heights);
    const tops = bruteTops(heights);
    expect(index.count).toBe(heights.length);
    expect(index.totalHeight).toBe(heights.reduce((sum, height) => sum + height, 0));
    expect([...index.materializeHeights()]).toEqual(heights);
    expect([...index.materializeTops()]).toEqual(tops);
    for (const at of [0, 1, 63, 64, 65, 127, 128, 191, 192])
      expect(index.topAt(at)).toBe(at === 192 ? index.totalHeight : tops[at]);
    for (const at of [0, 1, 63, 64, 65, 127, 128, 191]) expect(index.heightAt(at)).toBe(heights[at]);
  });

  test("updates one row without mutating the previous snapshot", () => {
    const before = PlacedHeightIndex.fromHeights([4, 5, 6, 7, 8, 9, 10]);
    const after = before.update(4, 30);
    expect(after).not.toBe(before);
    expect(before.heightAt(4)).toBe(8);
    expect(before.topAt(6)).toBe(39);
    expect(after.heightAt(4)).toBe(30);
    expect(after.topAt(6)).toBe(61);
    expect(after.totalHeight).toBe(71);
  });

  test("appends rows and preserves old geometry", () => {
    const before = PlacedHeightIndex.fromHeights(Array.from({ length: 70 }, () => 10));
    const after = before.append([2, 3, 4]);
    expect(before.count).toBe(70);
    expect(after.count).toBe(73);
    expect(before.totalHeight).toBe(700);
    expect(after.totalHeight).toBe(709);
    expect(after.topAt(70)).toBe(700);
    expect(after.materializeHeights().slice(68)).toEqual(new Float64Array([10, 10, 2, 3, 4]));
  });

  test("upper-bound lookup skips rows whose tops are equal", () => {
    const index = PlacedHeightIndex.fromHeights([0, 0, 12, 0, 8]);
    expect(index.upperBoundTop(-1)).toBe(0);
    expect(index.upperBoundTop(0)).toBe(3);
    expect(index.upperBoundTop(11)).toBe(3);
    expect(index.upperBoundTop(12)).toBe(5);
  });

  test("normalizes invalid measurements without shifting rows", () => {
    const index = PlacedHeightIndex.fromHeights([1, Number.NaN, Number.POSITIVE_INFINITY, -4, 2]);
    expect([...index.materializeHeights()]).toEqual([1, 0, 0, 0, 2]);
    expect(index.count).toBe(5);
    expect(index.totalHeight).toBe(3);
    expect(index.topAt(4)).toBe(1);
    const appended = index.append([Number.NaN, 3]);
    expect([...appended.materializeHeights()]).toEqual([1, 0, 0, 0, 2, 0, 3]);
  });

  test("re-sums fractional leaves when corrections settle to zero", () => {
    const values = [0.1, 0.2, ...Array.from({ length: 63 }, () => 0)];
    const index = PlacedHeightIndex.fromHeights(values).update(0, 0).update(1, 0);
    expect(index.totalHeight).toBe(0);
    expect(index.topAt(64)).toBe(0);
    expect(index.upperBoundTop(0)).toBe(65);
  });

  test("updates stay logarithmic in the number of rows", () => {
    const small = PlacedHeightIndex.fromHeights(new Float64Array(4_096).fill(20));
    const large = PlacedHeightIndex.fromHeights(new Float64Array(262_144).fill(20));
    const smallStart = performance.now();
    let smallNext = small;
    for (let index = 0; index < 1_000; index += 1) smallNext = smallNext.update(2_048, 21 + (index % 2));
    const smallMs = performance.now() - smallStart;
    const largeStart = performance.now();
    let largeNext = large;
    for (let index = 0; index < 1_000; index += 1) largeNext = largeNext.update(131_072, 21 + (index % 2));
    const largeMs = performance.now() - largeStart;
    expect(smallNext.totalHeight).toBe(largeNext.totalHeight - (262_144 - 4_096) * 20);
    // A generous ratio catches accidental full-array copies without making the
    // assertion depend on a particular machine's absolute clock speed.
    expect(largeMs).toBeLessThan(Math.max(50, smallMs * 8));
  });
});
