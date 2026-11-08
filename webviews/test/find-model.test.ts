import { expect, test } from "bun:test";
import { parsePatchFiles } from "@pierre/diffs";
import { collectFindMatches, reanchorActiveMatch, FIND_MATCH_CAP } from "../src/find/model";
import type { DiffItem } from "../src/diff-stream";

function itemsFromPatch(patch: string): DiffItem[] {
  const parsed = parsePatchFiles(patch) as Array<{ files: any[] }>;
  return parsed.flatMap((entry) => entry.files).map((fileDiff, index) => ({
    id: `item-${index}-${fileDiff.name}`,
    fileDiff,
  })) as DiffItem[];
}

const patch = [
  "diff --git a/a.txt b/a.txt",
  "index 0000000..1111111 100644",
  "--- a/a.txt",
  "+++ b/a.txt",
  "@@ -1,3 +1,4 @@",
  " context Needle",
  " plain line",
  "-removed needle line",
  "+added NEEDLE here",
  "+another line",
  "diff --git a/b.txt b/b.txt",
  "index 0000000..2222222 100644",
  "--- a/b.txt",
  "+++ b/b.txt",
  "@@ -10,2 +10,2 @@",
  " untouched",
  "-old needle needle",
  "+new text",
].join("\n") + "\n";

test("collectFindMatches finds matches on both sides in document order", () => {
  const items = itemsFromPatch(patch);
  const matches = collectFindMatches(items, "needle");

  expect(matches.map((m) => [m.itemId, m.side, m.lineNumber, m.start])).toEqual([
    // a.txt: context line (reported once, additions side), then the change
    // segment's deletion, then its addition.
    [items[0].id, "additions", 1, 8],
    [items[0].id, "deletions", 3, 8],
    [items[0].id, "additions", 3, 6],
    // b.txt: two occurrences on one deleted line.
    [items[1].id, "deletions", 11, 4],
    [items[1].id, "deletions", 11, 11],
  ]);
  // Case-insensitive: "Needle" and "NEEDLE" matched above.
  expect(matches[0].lineText).toBe("context Needle");
  expect(matches[4].occurrence).toBe(1);
});

test("collectFindMatches returns nothing for an empty query", () => {
  const items = itemsFromPatch(patch);
  expect(collectFindMatches(items, "")).toEqual([]);
});

test("collectFindMatches skips items without parsed hunks", () => {
  const items = [{ id: "binary", fileDiff: undefined } as unknown as DiffItem];
  expect(collectFindMatches(items, "x")).toEqual([]);
});

test("collectFindMatches caps pathological match counts", () => {
  const lines = Array.from({ length: 600 }, (_, i) => `+eeeeeeeeeeeeeeeeeeee${i}`);
  const bigPatch = [
    "diff --git a/big.txt b/big.txt",
    "index 0000000..3333333 100644",
    "--- a/big.txt",
    "+++ b/big.txt",
    `@@ -0,0 +1,${lines.length} @@`,
    ...lines,
  ].join("\n") + "\n";
  const items = itemsFromPatch(bigPatch);
  const matches = collectFindMatches(items, "e");
  expect(matches.length).toBe(FIND_MATCH_CAP);
});

test("reanchorActiveMatch keeps the same anchor when it survives", () => {
  const items = itemsFromPatch(patch);
  const matches = collectFindMatches(items, "needle");
  const previous = matches[3];
  // Same matches recomputed (new array identity) — anchor is found again.
  const recomputed = collectFindMatches(items, "needle");
  expect(reanchorActiveMatch(previous, recomputed, 0)).toBe(3);
});

test("reanchorActiveMatch clamps when the anchor disappears", () => {
  const items = itemsFromPatch(patch);
  const matches = collectFindMatches(items, "needle");
  const narrowed = collectFindMatches(items, "needle line");
  expect(narrowed.length).toBe(1);
  expect(reanchorActiveMatch(matches[4], narrowed, 4)).toBe(0);
  expect(reanchorActiveMatch(null, [], 2)).toBe(0);
});
