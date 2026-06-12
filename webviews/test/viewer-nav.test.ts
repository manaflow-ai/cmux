import { expect, test } from "bun:test";
import { adjacentItemId, buildHunkAnchors, nextHunkIndex } from "../src/viewer-nav";

const items = [
  {
    id: "a.txt",
    fileDiff: {
      hunks: [
        { additionStart: 3, additionCount: 2, additionLineIndex: 0, deletionStart: 3, deletionCount: 0, deletionLineIndex: 0 },
        { additionStart: 20, additionCount: 0, additionLineIndex: 2, deletionStart: 18, deletionCount: 4, deletionLineIndex: 0 },
      ],
    },
  },
  { id: "b.txt", fileDiff: { hunks: [] } },
  {
    id: "c.txt",
    fileDiff: {
      hunks: [
        { additionStart: 1, additionCount: 5, additionLineIndex: 0, deletionStart: 1, deletionCount: 1, deletionLineIndex: 0 },
      ],
    },
  },
];

test("buildHunkAnchors flattens hunks in item order, preferring the additions side", () => {
  const anchors = buildHunkAnchors(items);
  expect(anchors).toEqual([
    { itemId: "a.txt", itemIndex: 0, lineNumber: 3, side: "additions" },
    { itemId: "a.txt", itemIndex: 0, lineNumber: 18, side: "deletions" },
    { itemId: "c.txt", itemIndex: 2, lineNumber: 1, side: "additions" },
  ]);
});

test("buildHunkAnchors skips items without parsed hunks", () => {
  expect(buildHunkAnchors([{ id: "x" }, { id: "y", fileDiff: {} }])).toEqual([]);
});

test("nextHunkIndex walks forward and backward with clamping", () => {
  const anchors = buildHunkAnchors(items);
  expect(nextHunkIndex(anchors, -1, "", 1)).toBe(0);
  expect(nextHunkIndex(anchors, 0, "a.txt", 1)).toBe(1);
  expect(nextHunkIndex(anchors, 1, "a.txt", 1)).toBe(2);
  expect(nextHunkIndex(anchors, 2, "c.txt", 1)).toBe(2);
  expect(nextHunkIndex(anchors, 2, "c.txt", -1)).toBe(1);
  expect(nextHunkIndex(anchors, 0, "a.txt", -1)).toBe(0);
});

test("nextHunkIndex re-seeds from the active file after a file-level jump", () => {
  const anchors = buildHunkAnchors(items);
  // Last navigated hunk was in a.txt, but the user jumped to c.txt.
  expect(nextHunkIndex(anchors, 0, "c.txt", 1)).toBe(2);
});

test("nextHunkIndex returns -1 when there are no hunks", () => {
  expect(nextHunkIndex([], -1, "", 1)).toBe(-1);
});

test("adjacentItemId moves between files and clamps at the edges", () => {
  expect(adjacentItemId(items, "a.txt", 1)).toBe("b.txt");
  expect(adjacentItemId(items, "b.txt", -1)).toBe("a.txt");
  expect(adjacentItemId(items, "c.txt", 1)).toBeNull();
  expect(adjacentItemId(items, "a.txt", -1)).toBeNull();
  expect(adjacentItemId(items, "", 1)).toBe("a.txt");
  expect(adjacentItemId([], "a.txt", 1)).toBeNull();
});
