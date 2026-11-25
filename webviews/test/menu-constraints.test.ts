// The contrast rule of gallery/menuConstraints.ts (Leo 2026-11-22: "contrast when there are context
// menus above"): a menu's text against its glass fill laid over each surface under it, through every
// background between the text and the menu (a selected row, a badge).
import { expect, test } from "bun:test";
import { contrastRatio, over, parseCssColor, worstContrastOverGlass } from "../src/gallery/menuConstraints";

const GLASS = [0.1176, 0.1176, 0.1176, 0.72] as [number, number, number, number];

test("computed colours parse in rgb(), rgba() and color(srgb) forms", () => {
  expect(parseCssColor("rgb(255, 255, 255)")).toEqual([1, 1, 1, 1]);
  expect(parseCssColor("rgba(0, 0, 0, 0.5)")).toEqual([0, 0, 0, 0.5]);
  expect(parseCssColor("color(srgb 1 1 1 / 0.68)")).toEqual([1, 1, 1, 0.68]);
  expect(parseCssColor("transparent")).toBeUndefined();
});

test("black on white is 21:1 and a colour on itself is 1:1", () => {
  expect(contrastRatio([0, 0, 0], [1, 1, 1])).toBeCloseTo(21, 5);
  expect(contrastRatio([0.4, 0.4, 0.4], [0.4, 0.4, 0.4])).toBe(1);
  expect(over([1, 1, 1, 0.5], [0, 0, 0])).toEqual([0.5, 0.5, 0.5]);
});

test("soft text on the glass passes over a dark surface and fails over white", () => {
  const soft = [1, 1, 1, 0.68] as [number, number, number, number];
  expect(worstContrastOverGlass(soft, GLASS, [], [[0.12, 0.12, 0.12]])).toBeGreaterThan(4.5);
  expect(worstContrastOverGlass(soft, GLASS)).toBeLessThan(4.5);
});

test("a badge's own fill counts: a white tint under the text lowers its contrast", () => {
  const text = [1, 1, 1, 0.8] as [number, number, number, number];
  const dark: [number, number, number][] = [[0.12, 0.12, 0.12]];
  const plain = worstContrastOverGlass(text, GLASS, [], dark);
  const onBadge = worstContrastOverGlass(text, GLASS, [[1, 1, 1, 0.08]], dark);
  expect(onBadge).toBeLessThan(plain);
});
