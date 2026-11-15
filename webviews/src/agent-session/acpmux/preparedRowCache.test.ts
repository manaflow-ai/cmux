// l10n-allow-file: geometry fixtures, not shipped UI.
// The prepared text the transcript keeps per row (PreparedRow) is bounded: a chat at any length
// holds the same number of entries (cmuxterm-hq goals/chats-flat-at-any-length.md). Before the
// bound it held one per row ever measured, most of a long chat's live JS heap.
import { expect, test } from "bun:test";
import {
  layoutConversation,
  notePreparedText,
  PREPARED_ROWS,
  PREPARED_TEXT_CHARS,
  type AcpmuxRow,
  type PreparedRow,
  type RowHeights,
} from "./model";

/// Far above the bound, far below the chat's rows: a cache that grows with the chat fails it.
const CACHE_CEILING = 1_024;

const rows = (count: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, i) => ({
    id: `r${i}`,
    version: 1,
    at: 0,
    kind: i % 2 === 0 ? "user" : "assistant",
    text:
      i % 2 === 0
        ? `Question ${i}: what changed on the merged head?`
        : `Answer ${i}: the checks on the merged head are **green**, and ${"the lane wraps at a narrow width ".repeat(1 + (i % 4))}`,
  }));

test("laying out 20,000 rows keeps the prepared text cache under a constant", () => {
  const chat = rows(20_000);
  const cache = new Map<string, PreparedRow>();
  const known: RowHeights = new WeakMap();
  layoutConversation(chat, 720, cache, undefined, known);
  expect(cache.size).toBeLessThanOrEqual(CACHE_CEILING);
  // A chat that grows live (one turn at a time, each pass keeping the rows before it).
  let shown = chat.slice(0, 2);
  let layout = layoutConversation(shown, 720, cache, undefined, known);
  for (let at = 2; at < 4_000; at += 2) {
    const next = chat.slice(0, at + 2);
    layout = layoutConversation(next, 720, cache, undefined, known, { rows: shown, layout });
    shown = next;
  }
  expect(cache.size).toBeLessThanOrEqual(CACHE_CEILING);
  // A new width measures the whole chat again.
  layoutConversation(chat, 500, cache, undefined, known);
  expect(cache.size).toBeLessThanOrEqual(CACHE_CEILING);
});

// A new width with the view given (`near`), as the transcript lays out: the rows near the view and the
// ones still cached are measured at it; the rest keep their last height, as Chromium keeps an off-screen
// `content-visibility: auto` box's remembered size, until they draw or a layout measures them.
test("a new width measures the rows near the view and keeps the rest's last height", () => {
  const chat = rows(4_000);
  const cache = new Map<string, PreparedRow>();
  const known: RowHeights = new WeakMap();
  const wide = layoutConversation(chat, 900, cache, undefined, known);
  expect(cache.size).toBeLessThanOrEqual(PREPARED_ROWS);
  const exact = layoutConversation(chat, 500);
  const near = { from: 1_000, to: 1_100 };
  const narrow = layoutConversation(chat, 500, cache, undefined, known, undefined, undefined, undefined, near);
  // Near the view: this width's heights, the same as a whole layout's.
  expect(narrow.heights.slice(near.from, near.to)).toEqual(exact.heights.slice(near.from, near.to));
  expect(exact.heights.slice(near.from, near.to)).not.toEqual(wide.heights.slice(near.from, near.to));
  // Still cached when the pass began (the newest rows), though the near rows came first: this width's.
  expect(narrow.heights.slice(-PREPARED_ROWS)).toEqual(exact.heights.slice(-PREPARED_ROWS));
  // Elsewhere, its prepared text gone: the last width's heights, and the layout says so.
  expect(narrow.heights.slice(0, 900)).toEqual(wide.heights.slice(0, 900));
  expect(narrow.remembered).toBe(true);
  expect(exact.remembered).toBeUndefined();
  expect(cache.size).toBeLessThanOrEqual(PREPARED_ROWS);
  // A pass that keeps those rows (a streamed tail) still says so.
  const tail = [...chat.slice(0, -1), { ...chat.at(-1)!, version: 2, text: "Changed." }];
  const streamed = layoutConversation(
    tail,
    500,
    cache,
    undefined,
    known,
    { rows: chat, layout: narrow },
    undefined,
    undefined,
    near,
  );
  expect(streamed.remembered).toBe(true);
  // A layout with the view at them measures them at this width.
  const moved = layoutConversation(chat, 500, cache, undefined, known, undefined, undefined, undefined, {
    from: 0,
    to: 900,
  });
  expect(moved.heights.slice(0, 900)).toEqual(exact.heights.slice(0, 900));
  expect(cache.size).toBeLessThanOrEqual(PREPARED_ROWS);
});

// The text layout library's own segment cache is bounded too: it starts over after PREPARED_TEXT_CHARS
// characters prepared, as Blink's ShapeCache clears itself past its cap.
test("the text layout library's caches start over after a bounded amount of prepared text", () => {
  let clears = 0;
  const clear = () => {
    clears += 1;
  };
  // Whatever earlier tests counted: one clear starts the count over.
  for (let started = false; !started;) started = notePreparedText(PREPARED_TEXT_CHARS, clear);
  clears = 0;
  const line = 60;
  const lines = Math.ceil((PREPARED_TEXT_CHARS * 3) / line);
  for (let i = 0; i < lines; i += 1) notePreparedText(line, clear);
  expect(clears).toBe(2);
});
