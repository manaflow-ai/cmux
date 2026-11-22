import { expect, test } from "bun:test";
import { COLUMN_REACH, leadEdge, offColumn, offTokenGaps, sharedEdge, startEdge } from "../src/gallery/invariants";

test("the column is the edge most rows share", () => {
  expect(sharedEdge([24, 24, 24.2, 26])).toBe(24);
  expect(sharedEdge([10])).toBeNull();
  expect(sharedEdge([10, 20])).toBeNull();
});

test("a row a few px off the shared column breaks it; on it, or indented past reach, does not", () => {
  const rows = [
    { key: "row tool-1", edge: 24 },
    { key: "row tool-2", edge: 24.3 },
    { key: "row reply", edge: 26 },
    { key: "row nested", edge: 24 + COLUMN_REACH + 8 },
  ];
  const found = offColumn(rows, "icon-column", "the lead edge");
  expect(found.map(({ key }) => key)).toEqual(["icon-column:row reply"]);
  expect(found[0]!.detail).toContain("2 px");
});

test("a gap is 0, a token or two tokens", () => {
  const gaps = [
    { key: "a -> b", gap: 8 },
    { key: "b -> c", gap: 20 },
    { key: "c -> d", gap: 0 },
    { key: "d -> e", gap: 13 },
  ];
  expect(offTokenGaps(gaps, [4, 8, 12, 16]).map(({ key }) => key)).toEqual(["gap-token:d -> e"]);
});

test("a glyph up to 16 px leads at its 16 px box; a wider glyph (a reply footer's 20) is its own box", () => {
  expect(leadEdge({ left: 22, width: 12 })).toBe(20);
  expect(leadEdge({ left: 20, width: 16 })).toBe(20);
  expect(leadEdge({ left: 20, width: 20 })).toBe(20);
});

test("a menu label's edge is its start edge: right in an RTL row, left in an LTR row", () => {
  // Three RTL labels end on one right edge (200); one is 1.1 px wider, so its left edge is off.
  const labels = [
    { key: "menu a", left: 150, right: 200 },
    { key: "menu b", left: 148.9, right: 200 },
    { key: "menu c", left: 150, right: 200 },
  ];
  const edges = (rtl: boolean) => labels.map((label) => ({ key: label.key, edge: startEdge(label, rtl) }));
  expect(offColumn(edges(true), "menu-label", "the label")).toEqual([]);
  expect(offColumn(edges(false), "menu-label", "the label").map(({ key }) => key)).toEqual(["menu-label:menu b"]);
  expect(startEdge({ left: 10, right: 40 }, false)).toBe(10);
  expect(startEdge({ left: 10, right: 40 }, true)).toBe(40);
});
