import type { DiffItem } from "../diff-stream";
import { foldFind } from "./fold";

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

type FindHunkContent = { type: "context"; lines: number } | { type: "change"; additions: number; deletions: number };

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
  const haystack = foldFind(lineText);
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
  const query = foldFind(rawQuery);
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
              matches,
              query,
              item.id,
              "additions",
              additionLine,
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
              matches,
              query,
              item.id,
              "deletions",
              deletionLine,
              lineContent(deletionLines, deletionIndex),
            );
            deletionLine += 1;
            deletionIndex += 1;
          }
          for (let i = 0; i < segment.additions; i += 1) {
            pushLineMatches(
              matches,
              query,
              item.id,
              "additions",
              additionLine,
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
export function reanchorActiveMatch(previous: FindMatch | null, matches: FindMatch[], previousIndex: number): number {
  if (matches.length === 0) {
    return 0;
  }
  if (previous != null) {
    const found = matches.findIndex(
      (match) =>
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

/** Work counter for the bound tests (RFD 0199 section 11): lines the incremental find compared. */
export const diffFindWork = { lines: 0 };

const SIDE_ADDITIONS = 0;
const SIDE_DELETIONS = 1;

/** A file's searchable lines in `collectFindMatches` order, with each line folded once on first use. */
type FlatFile = {
  side: Uint8Array;
  lineNumber: Int32Array;
  index: Int32Array;
  lines: [string[], string[]];
  folded: [(string | undefined)[], (string | undefined)[]];
};

const EMPTY_FLAT: FlatFile = {
  side: new Uint8Array(0),
  lineNumber: new Int32Array(0),
  index: new Int32Array(0),
  lines: [[], []],
  folded: [[], []],
};

// Keyed by the parsed file @pierre/diffs owns, so it goes when the file does.
const flatFiles = new WeakMap<object, FlatFile>();

function flatFile(item: DiffItem): FlatFile {
  const fileDiff = item.fileDiff as FindFileDiff | undefined;
  if (fileDiff?.hunks == null) {
    return EMPTY_FLAT;
  }
  const cached = flatFiles.get(fileDiff);
  if (cached != null) {
    return cached;
  }
  const side: number[] = [];
  const lineNumber: number[] = [];
  const index: number[] = [];
  const push = (s: number, n: number, i: number) => {
    side.push(s);
    lineNumber.push(n);
    index.push(i);
  };
  for (const hunk of fileDiff.hunks) {
    let additionLine = hunk.additionStart;
    let deletionLine = hunk.deletionStart;
    let additionIndex = hunk.additionLineIndex;
    let deletionIndex = hunk.deletionLineIndex;
    for (const segment of hunk.hunkContent ?? []) {
      if (segment.type === "context") {
        for (let i = 0; i < segment.lines; i += 1) {
          push(SIDE_ADDITIONS, additionLine, additionIndex);
          additionLine += 1;
          deletionLine += 1;
          additionIndex += 1;
          deletionIndex += 1;
        }
      } else {
        for (let i = 0; i < segment.deletions; i += 1) {
          push(SIDE_DELETIONS, deletionLine, deletionIndex);
          deletionLine += 1;
          deletionIndex += 1;
        }
        for (let i = 0; i < segment.additions; i += 1) {
          push(SIDE_ADDITIONS, additionLine, additionIndex);
          additionLine += 1;
          additionIndex += 1;
        }
      }
    }
  }
  const flat: FlatFile = {
    side: Uint8Array.from(side),
    lineNumber: Int32Array.from(lineNumber),
    index: Int32Array.from(index),
    lines: [
      Array.isArray(fileDiff.additionLines) ? fileDiff.additionLines : [],
      Array.isArray(fileDiff.deletionLines) ? fileDiff.deletionLines : [],
    ],
    folded: [[], []],
  };
  flatFiles.set(fileDiff, flat);
  return flat;
}

function foldedAt(flat: FlatFile, entry: number): string {
  const side = flat.side[entry]!;
  const index = flat.index[entry]!;
  let line = flat.folded[side]![index];
  if (line == null) {
    line = foldFind(lineContent(flat.lines[side]!, index));
    flat.folded[side]![index] = line;
  }
  return line;
}

/**
 * `collectFindMatches` kept across calls (RFD 0199 section 11). While a diff streams in its items
 * only grow, so a new batch scans only the lines not scanned yet; a query that extends the
 * previous one checks only the lines the previous one matched (every line matching "abc" matched
 * "ab"); every line is folded once. The match cap holds as before: scanning stops at the cap and
 * resumes from where it stopped when a narrower query frees room. The answer always equals a fresh
 * `collectFindMatches(items, query)` (test/diff-find-scale.test.ts is the oracle).
 *
 * Lines are kept in three ordered runs: `hits` (checked, match the query), then `pending` (matched
 * an earlier prefix of the query, not checked yet), then everything from the scan cursor on.
 * Every line before the cursor in neither run is known not to match.
 */
export class IncrementalDiffFind {
  private query = "";
  private items: DiffItem[] = [];
  private files: unknown[] = [];
  private flats: FlatFile[] = [];
  private matches: FindMatch[] = [];
  private hitItem: number[] = [];
  private hitEntry: number[] = [];
  private pendingItem: number[] = [];
  private pendingEntry: number[] = [];
  private pendingFrom = 0;
  private cursorItem = 0;
  private cursorEntry = 0;
  private result: FindMatch[] = [];

  update(items: DiffItem[], rawQuery: string): FindMatch[] {
    const query = foldFind(rawQuery);
    let changed = false;
    // The items scanned so far must still be the first items (same id, same parsed file);
    // anything else (a deferred file loaded, a filter changed) starts over.
    let same = items.length >= this.items.length;
    for (let i = 0; same && i < this.items.length; i += 1) {
      const was = this.items[i]!;
      const now = items[i]!;
      same = was === now || (was.id === now.id && this.files[i] === now.fileDiff);
    }
    if (!same || query === "" || (query !== this.query && !(this.query !== "" && query.startsWith(this.query)))) {
      if (query !== this.query || this.items.length > 0) {
        changed = true;
      }
      this.reset(query);
    } else if (query !== this.query) {
      this.narrow(query);
      changed = true;
    }
    if (query !== "") {
      for (let i = this.items.length; i < items.length; i += 1) {
        const item = items[i]!;
        this.items.push(item);
        this.files.push(item.fileDiff);
        this.flats.push(flatFile(item));
        changed = true;
      }
      this.advance();
    }
    if (changed || this.result.length !== this.matches.length) {
      this.result = this.matches.slice();
    }
    return this.result;
  }

  private reset(query: string): void {
    this.query = query;
    this.items = [];
    this.files = [];
    this.flats = [];
    this.matches = [];
    this.hitItem = [];
    this.hitEntry = [];
    this.pendingItem = [];
    this.pendingEntry = [];
    this.pendingFrom = 0;
    this.cursorItem = 0;
    this.cursorEntry = 0;
  }

  private narrow(query: string): void {
    this.query = query;
    const candidateItem = this.hitItem.concat(this.pendingItem.slice(this.pendingFrom));
    const candidateEntry = this.hitEntry.concat(this.pendingEntry.slice(this.pendingFrom));
    this.pendingItem = candidateItem;
    this.pendingEntry = candidateEntry;
    this.pendingFrom = 0;
    this.hitItem = [];
    this.hitEntry = [];
    this.matches = [];
  }

  private capped(): boolean {
    return this.matches.length >= FIND_MATCH_CAP;
  }

  private advance(): void {
    while (this.pendingFrom < this.pendingItem.length && !this.capped()) {
      this.visit(this.pendingItem[this.pendingFrom]!, this.pendingEntry[this.pendingFrom]!);
      this.pendingFrom += 1;
    }
    while (this.cursorItem < this.flats.length && !this.capped()) {
      const flat = this.flats[this.cursorItem]!;
      const count = flat.side.length;
      while (this.cursorEntry < count && !this.capped()) {
        this.visit(this.cursorItem, this.cursorEntry);
        this.cursorEntry += 1;
      }
      if (this.cursorEntry >= count) {
        this.cursorItem += 1;
        this.cursorEntry = 0;
      }
    }
  }

  private visit(item: number, entry: number): void {
    diffFindWork.lines += 1;
    const flat = this.flats[item]!;
    const folded = foldedAt(flat, entry);
    const query = this.query;
    let start = folded.indexOf(query);
    if (start === -1) {
      return;
    }
    this.hitItem.push(item);
    this.hitEntry.push(entry);
    const side = flat.side[entry]!;
    const itemId = this.items[item]!.id;
    const matchSide: FindMatchSide = side === SIDE_ADDITIONS ? "additions" : "deletions";
    const lineNumber = flat.lineNumber[entry]!;
    const lineText = lineContent(flat.lines[side]!, flat.index[entry]!);
    let occurrence = 0;
    while (start !== -1 && !this.capped()) {
      this.matches.push({ itemId, side: matchSide, lineNumber, start, length: query.length, occurrence, lineText });
      occurrence += 1;
      start = folded.indexOf(query, start + Math.max(query.length, 1));
    }
  }
}
