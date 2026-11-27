// Open the file from the diff (D4): the file name in a file header, the header menu's open rows and
// a Cmd-click on a diff line call the host's `cmux.diff.openFile {path, line?, where?}`. The host
// opens only a file inside the tab's own repository and only on a real click or key; a deleted
// file has nothing to open, so the viewer offers no open for it.
import { useMemo } from "react";
import { diffPageClient } from "../diff/page";
import type { PageClient } from "../pages/shared/pageClient";
import { useSyncedRef } from "./useSyncedRef";

export const DIFF_OPEN_FILE_OP = "cmux.diff.openFile";

/** Where the host opens the file: a cmux file tab (at the line), the editor app, or Finder. */
export type DiffOpenTarget = "tab" | "editor" | "finder";

/** Opens a file of the diff, by its path relative to the repository. */
export type DiffFileOpen = (path: string, line?: number, where?: DiffOpenTarget) => void;

/** The host's open, when its config lists the op; undefined otherwise (the dev server, the classic viewer). */
export function diffFileOpenCall(
  page: PageClient | null,
  ops: readonly string[] | undefined,
): ((path: string, line?: number, where?: DiffOpenTarget) => Promise<unknown>) | undefined {
  if (!page || !ops?.includes(DIFF_OPEN_FILE_OP)) return undefined;
  return (path, line, where = "tab") =>
    page.call<unknown>(DIFF_OPEN_FILE_OP, { path, where, ...(line === undefined ? {} : { line }) });
}

/** The viewer's open: the host's, with `failed` run when the host refuses or nothing opened. */
export function useDiffFileOpen(ops: readonly string[] | undefined, failed: () => void): DiffFileOpen | undefined {
  const call = useMemo(() => diffFileOpenCall(diffPageClient(), ops), [ops]);
  const latest = useSyncedRef(failed);
  return useMemo(
    () =>
      call &&
      ((path, line, where) => {
        call(path, line, where).catch(() => latest.current());
      }),
    [call, latest],
  );
}

/** Whether the file is still in the work tree to open: not a deleted file, and named. */
export function opensFile<T extends { type?: unknown; name?: unknown }>(
  fileDiff: T | null | undefined,
): fileDiff is T & { name: string } {
  return fileDiff != null && fileDiff.type !== "deleted" && typeof fileDiff.name === "string" && fileDiff.name !== "";
}

/** A hunk's shape, as Pierre parses it from `@@ -deletionStart,deletionCount +additionStart,additionCount @@`. */
export type DiffHunkLines = {
  additionStart: number;
  additionCount: number;
  deletionStart: number;
  deletionCount: number;
  hunkContent: readonly (
    | { type: "context"; lines: number }
    | { type: "change"; deletions: number; additions: number }
  )[];
};

/** The first line a hunk covers on one side: git names the line before for an empty side (`-5,0`). */
const firstLine = (start: number, count: number) => (count === 0 ? start + 1 : start);

/**
 * The line of the file as it is now (the new side) for a clicked diff line. A new-side line is
 * itself. An old-side line maps through the hunks: an unchanged line to its new number, a removed
 * line to the added line that took its place, else to the line now at the removal (the line
 * before it at the end of the file). Lines between hunks shift by the hunks above them.
 */
export function newSideLine(
  hunks: readonly DiffHunkLines[],
  side: "additions" | "deletions",
  lineNumber: number,
): number {
  if (side === "additions") return Math.max(1, lineNumber);
  let shift = 0;
  for (const hunk of hunks) {
    const oldStart = firstLine(hunk.deletionStart, hunk.deletionCount);
    const newStart = firstLine(hunk.additionStart, hunk.additionCount);
    if (lineNumber < oldStart) break;
    const oldEnd = oldStart + hunk.deletionCount;
    if (lineNumber < oldEnd) return lineInHunk(hunk, oldStart, newStart, lineNumber);
    shift = newStart + hunk.additionCount - oldEnd;
  }
  return Math.max(1, lineNumber + shift);
}

function lineInHunk(hunk: DiffHunkLines, oldStart: number, newStart: number, lineNumber: number): number {
  // Within the hunk's new lines; a hunk that leaves none points at the line before it.
  const clamp = (line: number) =>
    hunk.additionCount === 0
      ? Math.max(1, hunk.additionStart)
      : Math.max(1, Math.min(line, newStart + hunk.additionCount - 1));
  let oldLine = oldStart;
  let newLine = newStart;
  for (const part of hunk.hunkContent) {
    if (part.type === "context") {
      if (lineNumber < oldLine + part.lines) return clamp(newLine + (lineNumber - oldLine));
      oldLine += part.lines;
      newLine += part.lines;
      continue;
    }
    if (lineNumber < oldLine + part.deletions) {
      return clamp(part.additions > 0 ? newLine + Math.min(lineNumber - oldLine, part.additions - 1) : newLine);
    }
    oldLine += part.deletions;
    newLine += part.additions;
  }
  return clamp(newLine);
}

/** What Pierre's `onLineClick` reports for a diff line (the fields this reads). */
export type DiffLineClick = {
  event: Pick<MouseEvent, "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "button" | "preventDefault">;
  lineNumber: number;
  annotationSide?: "additions" | "deletions";
};

/**
 * Whether the diff's new side is the files on disk, so a diff line names a line of the file there:
 * Unstaged, Uncommitted and Branch (the work tree against a base), and a patch (Last turn: the
 * files after the agent's turn). Staged shows the index and a commit shows that commit, so their
 * lines can be off; the file then opens at the top.
 */
export function linesMatchDisk(source: { kind: string } | null | undefined): boolean {
  return source?.kind === "unstaged" || source?.kind === "branch" || source?.kind === "patch";
}

/**
 * Whether a pointer press is Cmd on a diff line number: the viewer keeps it from Pierre, which
 * would start a line selection there and replace the person's selected lines and comment range.
 */
export function isCmdLineNumberPress(event: Pick<MouseEvent, "metaKey" | "button" | "composedPath">): boolean {
  if (!event.metaKey || event.button !== 0) return false;
  return event
    .composedPath()
    .some(
      (node) =>
        typeof (node as Element).hasAttribute === "function" && (node as Element).hasAttribute("data-column-number"),
    );
}

/**
 * A Cmd-click on a diff line opens the file at that line (Codex's review pane); any other click
 * keeps its own meaning (selecting text, the gutter). `atLine` false (``linesMatchDisk``) opens the
 * file at the top. Says what it did: `line`, `top`, or null for nothing.
 */
export function openFromLineClick(
  click: DiffLineClick,
  fileDiff: { type?: unknown; name?: unknown; hunks?: readonly DiffHunkLines[] } | null | undefined,
  open: DiffFileOpen | undefined,
  atLine = true,
): "line" | "top" | null {
  const { event } = click;
  if (!open || !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || event.button !== 0) return null;
  if (!opensFile(fileDiff)) return null;
  event.preventDefault();
  if (!atLine) {
    open(fileDiff.name);
    return "top";
  }
  open(fileDiff.name, newSideLine(fileDiff.hunks ?? [], click.annotationSide ?? "additions", click.lineNumber));
  return "line";
}
