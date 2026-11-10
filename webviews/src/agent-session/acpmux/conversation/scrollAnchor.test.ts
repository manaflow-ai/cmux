import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../model";
import { preserveScrollAnchorTop, scrollAnchorBase, settleFollowBottom } from "./scrollAnchor";

test("keeps a pending wheel's movement without reusing a browser resize adjustment", () => {
  expect(scrollAnchorBase(240, 320, true)).toBe(240);
  expect(scrollAnchorBase(340, 320, false)).toBe(320);
});

test("corrects a 5–8px measured growth instead of leaving the reader short of bottom", () => {
  for (const growth of [5, 6, 7, 8]) {
    const node = { scrollHeight: 1000 + growth, clientHeight: 600, scrollTop: 400 };
    expect(settleFollowBottom(node, 0, false)).toBe(true);
    expect(node.scrollTop).toBe(400 + growth);
  }
});

const row = (id: string, text: string): AcpmuxRow => ({ id, kind: "assistant", text, version: 1, at: 1 });

test("keeps the visible row fixed when a row above grows", () => {
  const oldRows = [row("above", "short"), row("anchor", "the row in view"), row("below", "tail")];
  const newRows = [{ ...oldRows[0], text: `${oldRows[0].text}\n${"more text ".repeat(90)}` }, ...oldRows.slice(1)];
  const oldLayout = layoutConversation(oldRows, 420);
  const newLayout = layoutConversation(newRows, 420);
  const oldTop = oldLayout.tops[1]! + 11;
  const next = preserveScrollAnchorTop({
    oldLayout,
    newLayout,
    oldRows,
    newRows,
    liveTop: oldTop,
    anchorTop: oldTop,
  });
  expect(next).toBe(oldTop + (newLayout.tops[1]! - oldLayout.tops[1]!));
  expect(next! - newLayout.tops[1]!).toBe(11);

  // WebKit may have applied the same adjustment before the layout effect runs.
  // The live value is already below the anchor; the correction must still be
  // based on the last reader offset, rather than applying the delta twice.
  const browserAdjusted = oldTop + (newLayout.tops[1]! - oldLayout.tops[1]!);
  const afterBrowserAdjustment = preserveScrollAnchorTop({
    oldLayout,
    newLayout,
    oldRows,
    newRows,
    liveTop: browserAdjusted,
    anchorTop: oldTop,
  });
  expect(afterBrowserAdjustment).toBe(browserAdjusted);
});

test("does not move the row itself when its streaming text grows", () => {
  const oldRows = [row("anchor", "the row in view"), row("below", "tail")];
  const newRows = [{ ...oldRows[0], text: `${oldRows[0].text}\n${"more text ".repeat(90)}` }, oldRows[1]];
  const oldLayout = layoutConversation(oldRows, 420);
  const newLayout = layoutConversation(newRows, 420);
  const oldTop = oldLayout.tops[0]! + 7;
  const next = preserveScrollAnchorTop({
    oldLayout,
    newLayout,
    oldRows,
    newRows,
    liveTop: oldTop,
    anchorTop: oldTop,
  });
  expect(next).toBe(oldTop);
});

test("keeps a reader's anchor when a live activity row is appended below it", () => {
  const oldRows = [row("prompt", "prompt"), row("anchor", "the row in view"), row("reply", "reply")];
  const activity = row("subagent-done", "Subagent finished");
  activity.kind = "activity";
  const newRows = [...oldRows, activity];
  const oldLayout = layoutConversation(oldRows, 420);
  const newLayout = layoutConversation(newRows, 420);
  const oldTop = oldLayout.tops[1]! + 9;
  const next = preserveScrollAnchorTop({
    oldLayout,
    newLayout,
    oldRows,
    newRows,
    liveTop: oldTop,
    anchorTop: oldTop,
  });
  expect(next! - newLayout.tops[1]!).toBe(9);
});

test("finds the same anchor after older history is inserted above it", () => {
  const oldRows = [row("before", "before"), row("anchor", "the row in view"), row("tail", "tail")];
  const inserted = Array.from({ length: 120 }, (_, index) => row(`old-${index}`, `old ${index}`));
  const newRows = [...inserted, ...oldRows];
  const oldLayout = layoutConversation(oldRows, 420);
  const newLayout = layoutConversation(newRows, 420);
  const oldTop = oldLayout.tops[1]! + 3;
  const next = preserveScrollAnchorTop({
    oldLayout,
    newLayout,
    oldRows,
    newRows,
    liveTop: oldTop,
    anchorTop: oldTop,
  });
  expect(next! - newLayout.tops[121]!).toBe(3);
});

// A fold ride (foldRide.ts) showed the rows under a growing row at their new tops by translate. The
// reader scrolled past it, and the placement that ends the ride puts those rows where they already
// show: the offset stays (review of #39917: "offset 1400 instead of 1200 after 200px").
test("rows a fold ride already showed lower move the offset by no more than is left", () => {
  const oldRows = [row("above", "short"), row("anchor", "the row in view"), row("below", "tail")];
  const newRows = [{ ...oldRows[0], text: `${oldRows[0].text}\n${"more text ".repeat(90)}` }, ...oldRows.slice(1)];
  const oldLayout = layoutConversation(oldRows, 420);
  const newLayout = layoutConversation(newRows, 420);
  const grown = newLayout.tops[1]! - oldLayout.tops[1]!;
  const top = oldLayout.tops[1]! + 11;
  const next = (shown: number) =>
    preserveScrollAnchorTop({
      oldLayout,
      newLayout,
      oldRows,
      newRows,
      liveTop: top,
      anchorTop: top,
      folds: [{ index: 0, delta: shown }],
    });
  expect(grown).toBeGreaterThan(0);
  expect(next(grown)).toBe(top);
  // Still shown 5px short of the growth, the view's top is in the growing row as shown: it holds.
  expect(next(grown - 5)).toBe(top);
  expect(next(0)).toBe(top + grown);
});

// A fold opened 100 -> 300 with the rows under it shown 200px lower by a ride; the reader scrolled
// 120px, into its open body, and the fold lands at 320. The row at the view's top is the folding row
// as the rows show, not the next row as the old layout put it: the offset stays (review of #39917 at
// 3b304dcc: "offset 140 instead of 120"). A close is the mirror image.
test("the anchor is the row a fold ride shows at the view's top", () => {
  const ids = [{ id: "fold" }, { id: "next" }, { id: "after" }];
  const layout = (heights: number[]) => {
    const tops = heights.map((_, at) => heights.slice(0, at).reduce((sum, each) => sum + each, 0));
    return { tops, heights, totalHeight: heights.reduce((sum, each) => sum + each, 0) };
  };
  const anchor = (old: number[], next: number[], shown: number, top: number) =>
    preserveScrollAnchorTop({
      oldLayout: layout(old),
      newLayout: layout(next),
      oldRows: ids,
      newRows: ids,
      liveTop: top,
      anchorTop: top,
      folds: [{ index: 0, delta: shown }],
    });
  expect(anchor([100, 100, 100], [320, 100, 100], 200, 120)).toBe(120);
  // A close 300 -> 120 shown 160px higher, the reader 150px down: in view is the next row, 10px in.
  expect(anchor([300, 100, 100], [120, 100, 100], -160, 150)).toBe(130);
});

// A prompt opened 500 -> 4500 with only the rows near it mounted; the reader scrolled 3900px, still
// inside its body. Rows the old layout puts at 3900 were never mounted and showed no translate, but
// they show 4000px lower too: the anchor is the prompt and the offset stays (review of #39917 at
// 4d8ff5ab: "corrects scrollTop 3900 to 7900, although 3900 remains inside the prompt").
test("the anchor is the folding row however far the view is into its body", () => {
  const count = 200;
  const ids = Array.from({ length: count }, (_, at) => ({ id: `row-${at}` }));
  const layout = (heights: number[]) => {
    const tops: number[] = [];
    let top = 0;
    for (const height of heights) {
      tops.push(top);
      top += height;
    }
    return { tops, heights, totalHeight: top };
  };
  const heights = (prompt: number) => Array.from({ length: count }, (_, at) => (at === 3 ? prompt : 100));
  const anchor = (top: number, folds: { index: number; delta: number }[]) =>
    preserveScrollAnchorTop({
      oldLayout: layout(heights(500)),
      newLayout: layout(heights(4500)),
      oldRows: ids,
      newRows: ids,
      liveTop: top,
      anchorTop: top,
      folds,
    });
  expect(anchor(3900, [{ index: 3, delta: 4000 }])).toBe(3900);
  // Past the open body, the rows under it as shown.
  expect(anchor(4850, [{ index: 3, delta: 4000 }])).toBe(4850);
  // Two folds: a row between them, and the lower fold's body.
  const two = [
    { index: 3, delta: 4000 },
    { index: 10, delta: -50 },
  ];
  expect(anchor(5150, two)).toBe(5150);
});
