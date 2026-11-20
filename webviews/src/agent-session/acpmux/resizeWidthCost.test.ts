// l10n-allow-file: geometry fixtures, not shipped UI.
// A divider dragged beside a long chat costs the rows near the view at each width the drag holds, and
// nothing per row at a width the rows were already measured at (Leo, 2026-11-18: "claude code desktop vs
// cmux next :( / we SLOW :(", a 700-turn chat stalling 0.9-1.5 s at each pause of the drag).
import { expect, test } from "bun:test";
import { layoutConversation, ROW_HEIGHT_WIDTHS, type AcpmuxRow, type PreparedRow, type RowHeights } from "./model";

const rows = (count: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, i) => ({
    id: `r${i}`,
    version: 1,
    at: 0,
    kind: i % 2 === 0 ? "user" : "assistant",
    text:
      i % 2 === 0
        ? `Question ${i}: what changed on the merged head?`
        : `Answer ${i}: the checks are **green**, and ${"the lane wraps at a narrow width ".repeat(1 + (i % 4))}`,
  }));

/// A measure that counts the rows it is asked for, with a height that depends on the width.
const counting = () => {
  const calls = { count: 0 };
  const measure = (_row: AcpmuxRow, width: number) => {
    calls.count += 1;
    return Math.ceil(12_000 / width) * 20;
  };
  return { calls, measure };
};

test("a row measured at a width keeps that height through the next widths, up to ROW_HEIGHT_WIDTHS", () => {
  const chat = rows(2_000);
  const known: RowHeights = new WeakMap();
  const cache = new Map<string, PreparedRow>();
  const { calls, measure } = counting();
  const wide = layoutConversation(chat, 800, cache, measure, known);
  // Dragged narrow through other widths, then back.
  const widths = Array.from({ length: ROW_HEIGHT_WIDTHS - 1 }, (_, i) => 700 - i * 100);
  for (const width of widths) layoutConversation(chat, width, cache, measure, known);
  calls.count = 0;
  const back = layoutConversation(chat, 800, cache, measure, known);
  expect(calls.count).toBe(0);
  expect(back.heights).toEqual(wide.heights);
  // One width more than are kept: the oldest is measured again.
  layoutConversation(chat, 300, cache, measure, known);
  layoutConversation(chat, 250, cache, measure, known);
  calls.count = 0;
  layoutConversation(chat, 800, cache, measure, known);
  expect(calls.count).toBe(chat.length);
});

test("at a new width with `near.all`, only the rows near the view are measured", () => {
  const chat = rows(2_000);
  const known: RowHeights = new WeakMap();
  const cache = new Map<string, PreparedRow>();
  const { calls, measure } = counting();
  const wide = layoutConversation(chat, 800, cache, measure, known);
  const near = { from: 1_000, to: 1_080, all: true };
  calls.count = 0;
  const narrow = layoutConversation(chat, 400, cache, measure, known, undefined, undefined, undefined, near);
  expect(calls.count).toBe(near.to - near.from);
  const exact = layoutConversation(chat, 400, undefined, measure);
  expect(narrow.heights.slice(near.from, near.to)).toEqual(exact.heights.slice(near.from, near.to));
  expect(narrow.heights.slice(0, near.from)).toEqual(wide.heights.slice(0, near.from));
  expect(narrow.remembered).toBe(true);
});

test("the text layout of a drag with `near.all` does not grow with the chat", () => {
  // Counted, not timed: a wall-clock bound fails on a loaded runner (164 ms against a 129 ms bound at
  // load 24 on 16 cores) and says nothing about which rows were laid out.
  const measured = (count: number) => {
    const chat = rows(count);
    const known: RowHeights = new WeakMap();
    const cache = new Map<string, PreparedRow>();
    const { calls, measure } = counting();
    layoutConversation(chat, 800, cache, measure, known);
    const near = { from: Math.floor(count / 2), to: Math.floor(count / 2) + 80, all: true };
    calls.count = 0;
    for (let width = 790; width > 400; width -= 30)
      layoutConversation(chat, width, cache, measure, known, undefined, undefined, undefined, near);
    return calls.count;
  };
  // Sixteen times the rows: the same rows near the view are laid out at each width of the drag.
  expect(measured(16_000)).toBe(measured(1_000));
  expect(measured(1_000)).toBe(80 * 13);
});
