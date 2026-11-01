import { expect, test } from "bun:test";
import { COLUMN_REACH, offColumn, offTokenGaps, sharedEdge } from "../src/gallery/invariants";

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
