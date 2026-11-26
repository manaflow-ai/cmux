import type { DiffItem } from "../diff-stream";

export type FindMatchSide = "additions" | "deletions";

export type FindMatch = {
  itemId: string;
  side: FindMatchSide;
  /** 1-based file line number on `side`. */
  lineNumber: number;
  /** 0-based character offset of the match within the line. */
  start: number;
  length: number;
  /** 0-based occurrence index of the query within this line. */
  occurrence: number;
  /** The line's text with its trailing newline stripped. */
  lineText: string;
};

type FindHunkContent =
  | { type: "context"; lines: number }
  | { type: "change"; additions: number; deletions: number };

type FindHunk = {
  additionStart: number;
  additionLineIndex: number;
  deletionStart: number;
  deletionLineIndex: number;
  hunkContent?: FindHunkContent[];
};

type FindFileDiff = {
  hunks?: FindHunk[];
  additionLines?: string[];
  deletionLines?: string[];
};

/** Bounds work on pathological queries ("e" in a 100k-line diff). */
export const FIND_MATCH_CAP = 9999;

// @pierre/diffs keeps each line's trailing newline; strip it so column
// offsets line up with the rendered text.
function lineContent(lines: string[], index: number): string {
  return (lines[index] ?? "").replace(/\r?\n$/, "");
}

function pushLineMatches(
  matches: FindMatch[],
  query: string,
  itemId: string,
  side: FindMatchSide,
  lineNumber: number,
  lineText: string,
): void {
  const haystack = lineText.toLowerCase();
  let from = 0;
  let occurrence = 0;
  for (;;) {
    const start = haystack.indexOf(query, from);
    if (start === -1 || matches.length >= FIND_MATCH_CAP) {
      return;
    }
    matches.push({ itemId, side, lineNumber, start, length: query.length, occurrence, lineText });
    occurrence += 1;
    from = start + Math.max(query.length, 1);
  }
}

/**
 * Case-insensitive substring search across every hunk line of every file in
 * the diff, in document order. Searches the diff MODEL, not the DOM: the
 * code view virtualizes rows, so off-screen lines do not exist in the DOM
 * and a DOM walk would systematically under-count.
 *
 * Context lines exist on both sides of the parsed diff; they are reported
 * once, on the additions side. Within a change segment, deletions precede
 * additions, matching the unified rendering order.
 */
export function collectFindMatches(items: DiffItem[], rawQuery: string): FindMatch[] {
  const query = rawQuery.toLowerCase();
  const matches: FindMatch[] = [];
  if (query === "") {
    return matches;
  }
  for (const item of items) {
    const fileDiff = item.fileDiff as FindFileDiff | undefined;
    if (fileDiff?.hunks == null) {
      continue;
    }
    const additionLines = Array.isArray(fileDiff.additionLines) ? fileDiff.additionLines : [];
    const deletionLines = Array.isArray(fileDiff.deletionLines) ? fileDiff.deletionLines : [];
    for (const hunk of fileDiff.hunks) {
      if (matches.length >= FIND_MATCH_CAP) {
        return matches;
      }
      let additionLine = hunk.additionStart;
      let deletionLine = hunk.deletionStart;
      let additionIndex = hunk.additionLineIndex;
      let deletionIndex = hunk.deletionLineIndex;
      for (const segment of hunk.hunkContent ?? []) {
        if (segment.type === "context") {
          for (let i = 0; i < segment.lines; i += 1) {
            pushLineMatches(
              matches, query, item.id, "additions", additionLine,
              lineContent(additionLines, additionIndex),
            );
            additionLine += 1;
            deletionLine += 1;
            additionIndex += 1;
            deletionIndex += 1;
          }
        } else {
          for (let i = 0; i < segment.deletions; i += 1) {
            pushLineMatches(
              matches, query, item.id, "deletions", deletionLine,
              lineContent(deletionLines, deletionIndex),
            );
            deletionLine += 1;
            deletionIndex += 1;
          }
          for (let i = 0; i < segment.additions; i += 1) {
            pushLineMatches(
              matches, query, item.id, "additions", additionLine,
              lineContent(additionLines, additionIndex),
            );
            additionLine += 1;
            additionIndex += 1;
          }
        }
      }
    }
  }
  return matches;
}

/**
 * The active-match index to keep when the match list is recomputed (items
 * streamed in, query edited). Prefers the same (item, side, line, occurrence)
 * anchor; falls back to clamping.
 */
export function reanchorActiveMatch(
  previous: FindMatch | null,
  matches: FindMatch[],
  previousIndex: number,
): number {
  if (matches.length === 0) {
    return 0;
  }
  if (previous != null) {
    const found = matches.findIndex((match) =>
      match.itemId === previous.itemId &&
      match.side === previous.side &&
      match.lineNumber === previous.lineNumber &&
      match.occurrence === previous.occurrence &&
      match.start === previous.start,
    );
    if (found !== -1) {
      return found;
    }
  }
  return Math.min(Math.max(previousIndex, 0), matches.length - 1);
}
