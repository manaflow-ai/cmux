// l10n-allow-file: geometry fixtures, not shipped UI.
// The prepared text the transcript keeps per row (PreparedRow) is bounded: a chat at any length
// holds the same number of entries (cmuxterm-hq goals/chats-flat-at-any-length.md). Before the
// bound it held one per row ever measured, most of a long chat's live JS heap.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow, type PreparedRow, type RowHeights } from "./model";

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
