import type { AnchorResult, DiffCommentRecord, DiffCommentSide } from "./types";

type CommentHunk = {
  additionStart: number;
  additionCount: number;
  additionLineIndex: number;
  deletionStart: number;
  deletionCount: number;
  deletionLineIndex: number;
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
  const text = sideLines(fileDiff, side)[index];
  return typeof text === "string" ? text : null;
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
      if (lines[lineIndex + offset] === comment.lineText) {
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
