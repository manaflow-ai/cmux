// The diff tab's Revert and hunk Stage (D3, the Codex Review pane's): the host's
// `cmux.diff.git.discard`, `.discardHunk`, `.undoDiscard`, `.stageHunk` and `.unstageHunk`
// (DiffPageProvider+Revert.swift, +Git.swift). The host runs each in the tab's own repository,
// asks for a real click or key, and shows its own sheet before a file loses its changes; the page
// only names what the person pressed. This file is the pure part: which scopes offer what, and a
// hunk's lines as git printed them.
import type { FileDiffMetadata } from "@pierre/diffs";
import type { DiffSource } from "../diff/generated/protocol";
import type { DiffItem } from "../diff-stream";
import type { PageClient } from "../pages/shared/pageClient";
import { UNCOMMITTED_BASE_REF } from "../toolbar-model";

export const DIFF_REVERT_OPS = {
  discard: "cmux.diff.git.discard",
  discardHunk: "cmux.diff.git.discardHunk",
  undoDiscard: "cmux.diff.git.undoDiscard",
} as const;

export const DIFF_HUNK_STAGE_OPS = {
  stage: "cmux.diff.git.stageHunk",
  unstage: "cmux.diff.git.unstageHunk",
} as const;

/** The most paths one request names (AgentPaneGitStage.maximumPaths). */
export const MAX_REQUEST_PATHS = 1000;

/** What Revert puts back: Unstaged to the index, Uncommitted to HEAD. */
export type RevertScope = "unstaged" | "uncommitted";

/**
 * Where Revert makes sense: Unstaged and Uncommitted (Branch against HEAD), whose changes are in
 * the work tree. Staged, Branch against a base and a patch show changes a revert of the work
 * tree would not undo, so they get none.
 */
export function revertScopeOf(source: DiffSource | null | undefined): RevertScope | undefined {
  if (source?.kind === "unstaged") return "unstaged";
  if (source?.kind === "branch" && source.baseRef === UNCOMMITTED_BASE_REF) return "uncommitted";
  return undefined;
}

/**
 * A hunk's Stage (Unstaged) or Unstage (Staged). The host stages a hunk of the index against the
 * work tree, which Uncommitted (HEAD against the work tree) shows only for files with nothing
 * staged, so Uncommitted, Branch and a patch get none.
 */
export function hunkStageModeOf(source: DiffSource | null | undefined): "stage" | "unstage" | undefined {
  if (source?.kind === "staged") return "unstage";
  if (source?.kind === "unstaged") return "stage";
  return undefined;
}

/** The host's Revert, Revert all and Undo. */
export type DiffReverter = {
  /** Reverts whole files after the host's sheet; rejects with `cmux.page.cancelled` when declined.
   *  `sources` are the paths that are a rename's previous path, so the sheet counts that file once. */
  discard: (paths: string[], scope: RevertScope, sources?: string[]) => Promise<unknown>;
  /** Reverts one hunk at once; resolves to the token its Undo names. */
  discardHunk: (paths: string[], hunk: string[], scope: RevertScope) => Promise<string | undefined>;
  undo: (token: string) => Promise<unknown>;
};

export type DiffRevertSource = {
  /** Revert, Revert all and Undo, when the host serves them. */
  revert?: DiffReverter;
  /** Stages (or unstages) one hunk, when the host serves it. */
  stageHunk?: (paths: string[], hunk: string[], unstage: boolean) => Promise<unknown>;
};

/**
 * The viewer's Revert and hunk Stage, each when the host lists all of its ops; undefined when it
 * lists neither. Hunk Stage does not need Revert: a host may serve Stage alone.
 */
export function diffRevertSource(
  page: PageClient | null,
  ops: readonly string[] | undefined,
): DiffRevertSource | undefined {
  if (!page) return undefined;
  const call = (op: string, params: Record<string, unknown>) => page.call<unknown>(op, params);
  const reverts = Object.values(DIFF_REVERT_OPS).every((op) => ops?.includes(op));
  const stages = Object.values(DIFF_HUNK_STAGE_OPS).every((op) => ops?.includes(op));
  if (!reverts && !stages) return undefined;
  return {
    ...(reverts
      ? {
          revert: {
            discard: (paths: string[], scope: RevertScope, sources?: string[]) =>
              call(DIFF_REVERT_OPS.discard, { paths, scope, ...(sources && sources.length > 0 ? { sources } : {}) }),
            discardHunk: async (paths: string[], hunk: string[], scope: RevertScope) => {
              const value = await call(DIFF_REVERT_OPS.discardHunk, { paths, hunk, scope });
              const undo = (value as { undo?: unknown } | null)?.undo;
              return typeof undo === "string" ? undo : undefined;
            },
            undo: (token: string) => call(DIFF_REVERT_OPS.undoDiscard, { undo: token }),
          },
        }
      : {}),
    ...(stages
      ? {
          stageHunk: (paths: string[], hunk: string[], unstage: boolean) =>
            call(unstage ? DIFF_HUNK_STAGE_OPS.unstage : DIFF_HUNK_STAGE_OPS.stage, { paths, hunk }),
        }
      : {}),
  };
}

/** The file's paths as the host names them: its path, then a rename's previous path. */
export function filePaths(path: string, previousPath: string | null | undefined): string[] {
  return previousPath && previousPath !== path ? [path, previousPath] : [path];
}

/**
 * A file's hunks take Stage and Revert one by one; a new, deleted or binary file goes whole. In
 * Uncommitted a rename is always staged, and the host refuses a hunk of a file with staged
 * changes there, so a rename goes whole too.
 */
export function hunksActionable(fileDiff: Partial<FileDiffMetadata> | undefined, scope?: RevertScope): boolean {
  if (!fileDiff || !Array.isArray(fileDiff.hunks) || fileDiff.hunks.length === 0) return false;
  return fileDiff.type === "change" || (fileDiff.type === "rename-changed" && scope !== "uncommitted");
}

/** The index of the hunk that holds `lineNumber` on `side`, or undefined between hunks. */
export function hunkIndexAt(
  fileDiff: Pick<FileDiffMetadata, "hunks">,
  side: "additions" | "deletions",
  lineNumber: number,
): number | undefined {
  const index = fileDiff.hunks.findIndex((hunk) =>
    side === "additions"
      ? lineNumber >= hunk.additionStart && lineNumber < hunk.additionStart + hunk.additionCount
      : lineNumber >= hunk.deletionStart && lineNumber < hunk.deletionStart + hunk.deletionCount,
  );
  return index >= 0 ? index : undefined;
}

/**
 * The line numbers of a hunk's first changed line on each side: where its Stage and Revert sit,
 * as in the Codex Review pane (one place per hunk, not the line under the pointer). A side the
 * first change block does not touch is missing; undefined for a hunk with no change.
 */
export function hunkFirstChange(
  fileDiff: Pick<FileDiffMetadata, "hunks">,
  index: number,
): { additions?: number; deletions?: number } | undefined {
  const hunk = fileDiff.hunks[index];
  if (!hunk) return undefined;
  let additions = 0;
  let deletions = 0;
  for (const content of hunk.hunkContent) {
    if (content.type === "context") {
      additions += content.lines;
      deletions += content.lines;
      continue;
    }
    if (content.additions + content.deletions === 0) continue;
    return {
      ...(content.deletions > 0 ? { deletions: hunk.deletionStart + deletions } : {}),
      ...(content.additions > 0 ? { additions: hunk.additionStart + additions } : {}),
    };
  }
  return undefined;
}

/**
 * The row of a hunk's first changed line in the file's rendered diff (Pierre's
 * `pre[data-diff-type]`, rows by `data-line` and `data-line-type`), the topmost when both sides
 * have one; undefined when it is not rendered (scrolled out of a long hunk).
 */
export function hunkAnchorRow(
  lineElement: Element,
  fileDiff: Pick<FileDiffMetadata, "hunks">,
  index: number,
): Element | undefined {
  const first = hunkFirstChange(fileDiff, index);
  const file = lineElement.closest("pre");
  if (!first || !file) return undefined;
  const rows = [
    first.deletions === undefined
      ? null
      : file.querySelector(`[data-line-type="change-deletion"][data-line="${first.deletions}"]`),
    first.additions === undefined
      ? null
      : file.querySelector(`[data-line-type="change-addition"][data-line="${first.additions}"]`),
  ].filter((row): row is Element => row !== null);
  return rows.sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
}

/** A diff line's text without its line ending: the host matches git's lines with `\r` dropped. */
function bare(line: string | undefined): string {
  return (line ?? "").replace(/\n$/, "").replace(/\r$/, "");
}

/**
 * The hunk's lines as git printed them, each ` `, `-` or `+` then the text: what the host finds in
 * its own read of the file's diff (AgentPaneGitHunk.patch). A change block prints its removed
 * lines before its added ones, as git does. Undefined for a hunk with no change.
 */
export function hunkLines(
  fileDiff: Pick<FileDiffMetadata, "hunks" | "additionLines" | "deletionLines">,
  index: number,
): string[] | undefined {
  const hunk = fileDiff.hunks[index];
  if (!hunk) return undefined;
  const lines: string[] = [];
  let changed = false;
  for (const content of hunk.hunkContent) {
    if (content.type === "context") {
      for (let at = 0; at < content.lines; at += 1)
        lines.push(" " + bare(fileDiff.additionLines[content.additionLineIndex + at]));
      continue;
    }
    for (let at = 0; at < content.deletions; at += 1)
      lines.push("-" + bare(fileDiff.deletionLines[content.deletionLineIndex + at]));
    for (let at = 0; at < content.additions; at += 1)
      lines.push("+" + bare(fileDiff.additionLines[content.additionLineIndex + at]));
    changed ||= content.deletions + content.additions > 0;
  }
  return changed ? lines : undefined;
}

/** Every file's paths for Stage all and Revert all, once each, in diff order. */
export function allPaths(
  items: readonly DiffItem[],
  pathOf: (item: DiffItem) => string,
  withPrevious: boolean,
): string[] {
  const seen = new Set<string>();
  for (const item of items) {
    const path = pathOf(item);
    const previous = typeof item.fileDiff?.prevName === "string" ? item.fileDiff.prevName : null;
    for (const each of withPrevious ? filePaths(path, previous) : [path]) seen.add(each);
  }
  return [...seen];
}

/** The rename sources among `items`: the previous paths Revert all names besides the new ones. */
export function renameSources(items: readonly DiffItem[], pathOf: (item: DiffItem) => string): string[] {
  return items.flatMap((item) => {
    const previous = item.fileDiff?.prevName;
    return typeof previous === "string" && previous !== pathOf(item) ? [previous] : [];
  });
}

/** `list` in runs of at most `size`. */
export function chunked<T>(list: readonly T[], size: number): T[][] {
  const runs: T[][] = [];
  for (let at = 0; at < list.length; at += size) runs.push(list.slice(at, at + size));
  return runs;
}
