import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../model";
import { preserveScrollAnchorTop, scrollAnchorBase } from "./scrollAnchor";

test("keeps a pending wheel's movement without reusing a browser resize adjustment", () => {
  expect(scrollAnchorBase(240, 320, true)).toBe(240);
  expect(scrollAnchorBase(340, 320, false)).toBe(320);
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
