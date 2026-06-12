// In-conversation search for the /agent-chat surface.
//
// Pure state + matching, no DOM: the UI reducer below drives the search bar
// (open/close, query, next/prev with wraparound, filter mode) and the matcher
// scans conversation items with a plain case-insensitive substring test (the
// query is never compiled into a regex). All scanning and highlighting is
// bounded per item so multi-megabyte tool outputs cannot freeze the render
// path: matching looks at the first MATCH_FIELD_SCAN_CHARS of each field, and
// highlighting decorates at most HIGHLIGHT_SCAN_CHARS / HIGHLIGHT_MAX_MARKS
// per text, passing the remainder through unhighlighted.

import type { ConversationItem } from "./protocol";

/** Per-field character cap when testing an item for a match. */
export const MATCH_FIELD_SCAN_CHARS = 100_000;
/** Character cap for match decoration within a single rendered text. */
export const HIGHLIGHT_SCAN_CHARS = 20_000;
/** Cap on highlighted segments within a single rendered text. */
export const HIGHLIGHT_MAX_MARKS = 100;

// ---------------------------------------------------------------------------
// Search bar UI state (reducer-shaped so document-level key handlers can hold
// a stable dispatch instead of stale state closures).
// ---------------------------------------------------------------------------

export type SearchUIState = {
  open: boolean;
  /** Bumps on every open request; keys the input so repeat Cmd+F refocuses. */
  openCount: number;
  query: string;
  /** When on, the timeline shows only matching items. */
  filterMode: boolean;
  /** Position in the match list; clamp against the live list via clampCursor. */
  cursor: number;
};

export type SearchUIAction =
  | { type: "open" }
  | { type: "close" }
  | { type: "set-query"; query: string }
  | { type: "step"; direction: 1 | -1; matchCount: number }
  | { type: "toggle-filter" };

export function initialSearchUIState(): SearchUIState {
  return { open: false, openCount: 0, query: "", filterMode: false, cursor: 0 };
}

export function reduceSearchUI(state: SearchUIState, action: SearchUIAction): SearchUIState {
  switch (action.type) {
    case "open":
      return { ...state, open: true, openCount: state.openCount + 1 };
    case "close":
      // Escape both dismisses the bar and clears the query, restoring the
      // unfiltered timeline and auto-follow. Filter mode stays sticky for the
      // next search.
      if (!state.open) {
        return state;
      }
      return { ...state, open: false, query: "", cursor: 0 };
    case "set-query":
      return { ...state, query: action.query, cursor: 0 };
    case "step": {
      if (action.matchCount <= 0) {
        return state;
      }
      const current = clampCursor(state.cursor, action.matchCount);
      const next = (current + action.direction + action.matchCount) % action.matchCount;
      return { ...state, cursor: next };
    }
    case "toggle-filter":
      return { ...state, filterMode: !state.filterMode };
  }
}

/** Clamps a stored cursor against the current match count (items can shrink). */
export function clampCursor(cursor: number, matchCount: number): number {
  if (matchCount <= 0) {
    return 0;
  }
  return Math.min(Math.max(cursor, 0), matchCount - 1);
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/** A whitespace-only query matches nothing; otherwise match the raw text. */
export function normalizeSearchQuery(query: string): string {
  return query.trim() === "" ? "" : query.toLowerCase();
}

function fieldMatches(field: string | undefined, lowerQuery: string): boolean {
  if (field === undefined || field === "") {
    return false;
  }
  return field.slice(0, MATCH_FIELD_SCAN_CHARS).toLowerCase().includes(lowerQuery);
}

/**
 * Input keys whose string values the rich tool rows visibly render: command
 * lines, file paths (Read/Edit/Write/notebooks), web search queries/URLs, and
 * Codex apply_patch text (file paths live inside it). Searching for what a
 * row displays must match that row.
 */
const SEARCHED_INPUT_KEYS = [
  "command",
  "path",
  "file_path",
  "notebook_path",
  "query",
  "url",
  "patch",
] as const;

function inputMatches(input: unknown, lowerQuery: string): boolean {
  if (typeof input === "string") {
    return fieldMatches(input, lowerQuery);
  }
  if (typeof input === "object" && input !== null) {
    const record = input as Record<string, unknown>;
    for (const key of SEARCHED_INPUT_KEYS) {
      const value = record[key];
      if (typeof value === "string" && fieldMatches(value, lowerQuery)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Case-insensitive substring match over the item's renderable text: message /
 * reasoning / plan bodies, tool titles and names, tool output, and the input
 * strings the tool rows display (command, paths, queries, patch text).
 */
export function itemMatchesQuery(item: ConversationItem, lowerQuery: string): boolean {
  if (lowerQuery === "") {
    return false;
  }
  return (
    fieldMatches(item.text, lowerQuery) ||
    fieldMatches(item.title, lowerQuery) ||
    fieldMatches(item.tool_name, lowerQuery) ||
    fieldMatches(item.output?.text, lowerQuery) ||
    inputMatches(item.input, lowerQuery)
  );
}

// Per-item match cache. Conversation items are immutable value snapshots:
// streamed updates replace only the changed item object, so caching by object
// identity makes the per-render scan incremental — unchanged items are cache
// hits and only the item that actually changed (or a query change) pays a
// scan. This is what keeps an open search from re-lowercasing megabytes of
// tool output on every streamed event.
const matchCache = new WeakMap<ConversationItem, { query: string; matched: boolean }>();

/**
 * Indexes (into `items`) of the items matching `query`, in timeline order.
 * `onScan` is a test seam reporting cache misses (real scans).
 */
export function computeMatches(
  items: readonly ConversationItem[],
  query: string,
  onScan?: (item: ConversationItem) => void,
): number[] {
  const lowerQuery = normalizeSearchQuery(query);
  if (lowerQuery === "") {
    return [];
  }
  const matches: number[] = [];
  items.forEach((item, index) => {
    const cached = matchCache.get(item);
    let matched: boolean;
    if (cached !== undefined && cached.query === lowerQuery) {
      matched = cached.matched;
    } else {
      onScan?.(item);
      matched = itemMatchesQuery(item, lowerQuery);
      matchCache.set(item, { query: lowerQuery, matched });
    }
    if (matched) {
      matches.push(index);
    }
  });
  return matches;
}

// ---------------------------------------------------------------------------
// Highlighting
// ---------------------------------------------------------------------------

export type HighlightSegment = { text: string; match: boolean };

/**
 * Splits `text` into plain/match segments for `<mark>` rendering. Bounded:
 * only the first HIGHLIGHT_SCAN_CHARS are scanned and at most
 * HIGHLIGHT_MAX_MARKS matches are decorated; everything beyond is returned as
 * one plain trailing segment, so segment output never exceeds
 * 2 * HIGHLIGHT_MAX_MARKS + 2 entries regardless of input size.
 */
export function highlightSegments(text: string, query: string): HighlightSegment[] {
  const lowerQuery = normalizeSearchQuery(query);
  if (text === "" || lowerQuery === "") {
    return [{ text, match: false }];
  }
  const region = text.slice(0, HIGHLIGHT_SCAN_CHARS);
  let lowerRegion = region.toLowerCase();
  if (lowerRegion.length !== region.length) {
    // Rare locale-sensitive case folds change string length and would skew
    // segment offsets; fall back to case-sensitive matching for this text.
    lowerRegion = region;
  }
  const segments: HighlightSegment[] = [];
  let position = 0;
  let marks = 0;
  while (marks < HIGHLIGHT_MAX_MARKS) {
    const found = lowerRegion.indexOf(lowerQuery, position);
    if (found === -1) {
      break;
    }
    if (found > position) {
      segments.push({ text: region.slice(position, found), match: false });
    }
    segments.push({ text: region.slice(found, found + lowerQuery.length), match: true });
    position = found + lowerQuery.length;
    marks += 1;
  }
  if (position < text.length) {
    segments.push({ text: region.slice(position) + text.slice(region.length), match: false });
  }
  return segments.length > 0 ? segments : [{ text, match: false }];
}
