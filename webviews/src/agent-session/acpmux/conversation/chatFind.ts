// Find in Chat: matches of a query in the transcript's prompts and replies, the one the reader is
// on, and the highlights over the rows on screen (CSS custom highlights, so the rendered rows are
// never rewritten). The transcript is virtualized: matches come from the rows' text, and a row
// draws its highlights once it mounts.
import { useCallback, useMemo, useState } from "react";
import type { AcpmuxRow } from "../model";

/** One match: the `occurrence`th match of the query in row `rowIndex`. */
export type FindMatch = { rowIndex: number; rowId: string; occurrence: number };

/** The highlight names conversation.css styles. */
export const FIND_HIGHLIGHT = "acpmux-find";
export const FIND_ACTIVE_HIGHLIGHT = "acpmux-find-active";

const SEARCHED_KINDS = new Set(["user", "assistant"]);

/** Every match of `query` (case-insensitive) in the prompts and replies of `rows`, in order. */
export function findMatches(rows: readonly AcpmuxRow[], query: string): FindMatch[] {
  const needle = query.toLocaleLowerCase();
  if (!needle) return [];
  const matches: FindMatch[] = [];
  rows.forEach((row, rowIndex) => {
    if (!SEARCHED_KINDS.has(row.kind) || !row.text) return;
    const text = row.text.toLocaleLowerCase();
    let occurrence = 0;
    for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length))
      matches.push({ rowIndex, rowId: row.id, occurrence: occurrence++ });
  });
  return matches;
}

export type ChatFind = {
  open: boolean;
  query: string;
  matches: FindMatch[];
  /** The index in `matches` of the current match; 0 when there are none. */
  active: number;
  /** Opens the bar, with `text` as the query when given. Bumps `focusRequest`. */
  show: (text?: string) => void;
  hide: () => void;
  setQuery: (query: string) => void;
  next: () => void;
  previous: () => void;
  /** Changes on each `show`, so the bar focuses its field again. */
  focusRequest: number;
};

/** The find state of a transcript of `rows`. */
export function useChatFind(rows: readonly AcpmuxRow[]): ChatFind {
  const [open, setOpen] = useState(false);
  const [query, setQueryState] = useState("");
  const [active, setActive] = useState(0);
  const [focusRequest, setFocusRequest] = useState(0);
  const matches = useMemo(() => (open ? findMatches(rows, query) : []), [open, rows, query]);
  const count = matches.length;
  const current = count ? Math.min(active, count - 1) : 0;
  const show = useCallback((text?: string) => {
    setOpen(true);
    if (text) {
      setQueryState(text);
      setActive(0);
    }
    setFocusRequest((request) => request + 1);
  }, []);
  const hide = useCallback(() => setOpen(false), []);
  const setQuery = useCallback((next: string) => {
    setQueryState(next);
    setActive(0);
  }, []);
  const step = useCallback(
    (by: number) => {
      if (!count) return;
      setOpen(true);
      setActive((index) => (Math.min(index, count - 1) + by + count) % count);
    },
    [count],
  );
  const next = useCallback(() => step(1), [step]);
  const previous = useCallback(() => step(-1), [step]);
  return { open, query, matches, active: current, show, hide, setQuery, next, previous, focusRequest };
}

type HighlightRegistry = { set(name: string, value: unknown): void; delete(name: string): void };

function registry(): HighlightRegistry | undefined {
  return (globalThis.CSS as unknown as { highlights?: HighlightRegistry } | undefined)?.highlights;
}

/** Clears the find highlights. */
export function clearFindHighlights() {
  const highlights = registry();
  highlights?.delete(FIND_HIGHLIGHT);
  highlights?.delete(FIND_ACTIVE_HIGHLIGHT);
}

/**
 * Highlights `query` in the rows mounted under `root` (elements with `data-row-id`), and `active`
 * apart from the rest. A match that spans formatting (a bold word inside it) is not drawn. Returns
 * the active match's range when its row is mounted (its last match when the drawn text has fewer
 * than the row's text, such as a link's hidden address).
 */
export function paintFindHighlights(root: HTMLElement, query: string, active?: FindMatch): Range | undefined {
  const highlights = registry();
  const Highlight = (globalThis as unknown as { Highlight?: new (...ranges: Range[]) => unknown }).Highlight;
  const needle = query.toLocaleLowerCase();
  if (!highlights || !Highlight || !needle) {
    clearFindHighlights();
    return undefined;
  }
  const all: Range[] = [];
  let current: Range | undefined;
  for (const row of root.querySelectorAll<HTMLElement>("[data-row-id]")) {
    const ranges: Range[] = [];
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent?.toLocaleLowerCase() ?? "";
      for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) {
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + needle.length);
        ranges.push(range);
      }
    }
    all.push(...ranges);
    if (active && row.dataset.rowId === active.rowId && ranges.length)
      current = ranges[Math.min(active.occurrence, ranges.length - 1)];
  }
  highlights.set(FIND_HIGHLIGHT, new Highlight(...all.filter((range) => range !== current)));
  if (current) highlights.set(FIND_ACTIVE_HIGHLIGHT, new Highlight(current));
  else highlights.delete(FIND_ACTIVE_HIGHLIGHT);
  return current;
}
