// How late (phase B) rows join the card (OmniboxMerge.swift): no row at or above the highlighted
// row moves; new rows fill free slots below in rank order; when the card is full, a new row
// replaces only the lowest-ranked row below the highlight, and only when it outranks it.
import type { BrowserSuggestion } from "./types";
import { urlDisplayText } from "./url-display";

/** `BrowserHistoryRanker.dedupeKey`: one row per page. */
export function dedupeKey(url: string): string {
  let text = urlDisplayText(url).toLowerCase();
  if (text.startsWith("http://")) text = text.slice(7);
  if (text.endsWith("/")) text = text.slice(0, -1);
  return text;
}

/** One row per page; one search row per query text. */
function mergeKey(row: BrowserSuggestion): string {
  return row.kind === "search" ? `search:${row.title.toLowerCase()}` : dedupeKey(row.url);
}

export function mergeSuggestions(
  visible: readonly BrowserSuggestion[],
  highlight: number,
  incoming: readonly BrowserSuggestion[],
  capacity: number,
): BrowserSuggestion[] {
  const rows = [...visible];
  const keys = new Set(rows.map(mergeKey));
  const frozen = Math.max(highlight, 0);
  const ranked = incoming
    .map((row, offset) => ({ row, offset }))
    .sort((a, b) => (a.row.score !== b.row.score ? b.row.score - a.row.score : a.offset - b.offset))
    .map(({ row }) => row);
  for (const row of ranked) {
    const key = mergeKey(row);
    if (keys.has(key)) continue;
    if (rows.length < capacity) {
      rows.push(row);
      keys.add(key);
      continue;
    }
    // The lowest-ranked row below the highlight; the lowest on screen among equals.
    let victim = -1;
    for (let index = frozen + 1; index < rows.length; index++) {
      if (victim < 0 || rows[index].score <= rows[victim].score) victim = index;
    }
    if (victim < 0 || rows[victim].score >= row.score) continue;
    keys.delete(mergeKey(rows[victim]));
    rows[victim] = row;
    keys.add(key);
  }
  return rows;
}
