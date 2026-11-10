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
      shown: (index) => (index >= 1 ? shown : 0),
    });
  expect(grown).toBeGreaterThan(0);
  expect(next(grown)).toBe(top);
  expect(next(grown - 5)).toBe(top + 5);
  expect(next(0)).toBe(top + grown);
});
