import type { AnchorResult, DiffCommentRecord, DiffCommentSide } from "./types";

type CommentHunkContent =
  | { type: "context"; lines: number; additionLineIndex: number; deletionLineIndex: number }
  | { type: "change"; additions: number; additionLineIndex: number; deletions: number; deletionLineIndex: number };

type CommentHunk = {
  additionStart: number;
  additionCount: number;
  additionLineIndex: number;
  deletionStart: number;
  deletionCount: number;
  deletionLineIndex: number;
  hunkContent?: CommentHunkContent[];
};

export type CommentFileDiff = {
  hunks?: CommentHunk[];
  additionLines?: string[];
  deletionLines?: string[];
};

const excerptLineCap = 40;

function hunkRange(hunk: CommentHunk, side: DiffCommentSide): { start: number; count: number; lineIndex: number } {
  return side === "additions"
    ? { start: hunk.additionStart, count: hunk.additionCount, lineIndex: hunk.additionLineIndex }
    : { start: hunk.deletionStart, count: hunk.deletionCount, lineIndex: hunk.deletionLineIndex };
}


function lineContent(lines: string[], index: number): string {
  // @pierre/diffs keeps each line's trailing newline; strip it so excerpts,
  // anchors, and previews never double-space.
  return (lines[index] ?? "").replace(/\r?\n$/, "");
}

function sideLines(fileDiff: CommentFileDiff | null | undefined, side: DiffCommentSide): string[] {
  const lines = side === "additions" ? fileDiff?.additionLines : fileDiff?.deletionLines;
  return Array.isArray(lines) ? lines : [];
}

/**
 * Maps a 1-based file line number on the given diff side to the zero-based
 * index into `additionLines`/`deletionLines`, by walking the file's hunks.
 * Returns null when the line is not covered by any hunk.
 */
export function lineIndexFor(
  fileDiff: CommentFileDiff | null | undefined,
  side: DiffCommentSide,
  lineNumber: number,
): number | null {
  if (fileDiff?.hunks == null || !Number.isFinite(lineNumber)) {
    return null;
  }
  for (const hunk of fileDiff.hunks) {
    const { start, count, lineIndex } = hunkRange(hunk, side);
    if (lineNumber >= start && lineNumber < start + count) {
      return lineIndex + (lineNumber - start);
    }
  }
  return null;
}

export function lineTextFor(
  fileDiff: CommentFileDiff | null | undefined,
  side: DiffCommentSide,
  lineNumber: number,
): string | null {
  const index = lineIndexFor(fileDiff, side, lineNumber);
  if (index == null) {
    return null;
  }
  const lines = sideLines(fileDiff, side);
  return index < lines.length ? lineContent(lines, index) : null;
}

/**
 * Re-anchors a saved comment against the current fileDiff. Anchored when the
 * saved line still has the saved text; moved when exactly one line reachable
 * through the hunks on that side carries the saved text; outdated otherwise.
 */
export function anchorComment(
  fileDiff: CommentFileDiff | null | undefined,
  comment: Pick<DiffCommentRecord, "side" | "endLine" | "lineText">,
): AnchorResult {
  if (lineTextFor(fileDiff, comment.side, comment.endLine) === comment.lineText) {
    return { state: "anchored", line: comment.endLine };
  }
  const lines = sideLines(fileDiff, comment.side);
  const matches = new Set<number>();
  for (const hunk of fileDiff?.hunks ?? []) {
    const { start, count, lineIndex } = hunkRange(hunk, comment.side);
    for (let offset = 0; offset < count; offset += 1) {
      if (lineContent(lines, lineIndex + offset) === comment.lineText) {
        matches.add(start + offset);
      }
    }
  }
  if (matches.size === 1) {
    const line = matches.values().next().value as number;
    return { state: "moved", line, delta: line - comment.endLine };
  }
  return { state: "outdated" };
}

/**
 * Builds a unified-diff excerpt (` `/`-`/`+` prefixed rows) for the hunk
 * region the commented range touches. Whole change blocks are kept so `-`
 * rows stay paired with their `+` rows; context is trimmed to the commented
 * range. Falls back to "" when the file has no hunk content (capped rows).
 */
export function diffExcerptFor(
  fileDiff: CommentFileDiff | null | undefined,
  side: DiffCommentSide,
  startLine: number,
  endLine: number,
): string {
  const first = Math.min(startLine, endLine);
  const last = Math.max(startLine, endLine);
  const additionLines = fileDiff?.additionLines ?? [];
  const deletionLines = fileDiff?.deletionLines ?? [];
  const rows: string[] = [];
  for (const hunk of fileDiff?.hunks ?? []) {
    const range = hunkRange(hunk, side);
    if (last < range.start || first >= range.start + range.count || hunk.hunkContent == null) {
      continue;
    }
    let additionLine = hunk.additionStart;
    let deletionLine = hunk.deletionStart;
    for (const content of hunk.hunkContent) {
      if (content.type === "context") {
        for (let offset = 0; offset < content.lines; offset += 1) {
          const lineNumber = side === "additions" ? additionLine + offset : deletionLine + offset;
          if (lineNumber >= first && lineNumber <= last) {
            rows.push(` ${lineContent(additionLines, content.additionLineIndex + offset)}`);
          }
        }
        additionLine += content.lines;
        deletionLine += content.lines;
        continue;
      }
      const blockTouchesRange = side === "additions"
        ? content.additions > 0 && additionLine <= last && additionLine + content.additions - 1 >= first
        : content.deletions > 0 && deletionLine <= last && deletionLine + content.deletions - 1 >= first;
      if (blockTouchesRange) {
        for (let offset = 0; offset < content.deletions; offset += 1) {
          rows.push(`-${lineContent(deletionLines, content.deletionLineIndex + offset)}`);
        }
        for (let offset = 0; offset < content.additions; offset += 1) {
          rows.push(`+${lineContent(additionLines, content.additionLineIndex + offset)}`);
        }
      }
      additionLine += content.additions;
      deletionLine += content.deletions;
    }
  }
  return rows.slice(0, excerptLineCap).join("\n");
}

/**
 * Builds a plain-text excerpt of the commented lines with `N: ` line-number
 * prefixes. Lines not present in the diff are skipped; capped at 40 lines.
 */
export function excerptFor(
  fileDiff: CommentFileDiff | null | undefined,
  side: DiffCommentSide,
  startLine: number,
  endLine: number,
): string {
  const first = Math.min(startLine, endLine);
  const last = Math.max(startLine, endLine);
  const lines: string[] = [];
  for (let line = first; line <= last && lines.length < excerptLineCap; line += 1) {
    const text = lineTextFor(fileDiff, side, line);
    if (text == null) {
      continue;
    }
    lines.push(`${line}: ${text}`);
  }
  return lines.join("\n");
}
