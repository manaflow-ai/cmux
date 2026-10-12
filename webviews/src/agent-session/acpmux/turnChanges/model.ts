// The edited-files card's data, apart from its React view (it may later move into the thread
// widget system): the turn's files with their counts and what Undo can do for each, built from the
// ACP tool calls' `diff` contents (path, oldText, newText).
//
// Undo is a host revert (`turn.undo`, Swift AgentPaneTurnUndo): for each file the host writes the
// turn's FIRST oldText back only while the file still holds exactly the turn's LAST newText. The
// page can offer it only when those two texts are the whole file: every later edit's oldText is
// the previous edit's newText. An edit sent as a fragment (Claude's Edit sends old_string and
// new_string) breaks that chain unless the fragment is the whole file, which the host's exact
// compare then proves. Never git, never the agent.
import type { AcpmuxFileDiff, AcpmuxRow } from "../model";

/// What Undo can do for one file.
export type FileUndo =
  /// Write `before` back while the file holds `after`.
  | { kind: "revert"; before: string; after: string }
  /// The turn created the file: move it to the Trash while it holds `after`.
  | { kind: "trash"; after: string }
  /// No full before and after text: "Cannot undo this edit".
  | { kind: "cannot" };

export type EditedFile = { path: string; added: number; removed: number; undo: FileUndo };
export type TurnChanges = { turnId: string; files: EditedFile[] };

/// The tool-call diffs of `rows` per path, in order. A failed tool call wrote nothing.
export function diffsByPath(rows: readonly AcpmuxRow[]): Map<string, AcpmuxFileDiff[]> {
  const byPath = new Map<string, AcpmuxFileDiff[]>();
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (!tool || tool.status === "failed") continue;
      for (const diff of tool.diffs ?? []) byPath.set(diff.path, [...(byPath.get(diff.path) ?? []), diff]);
    }
  }
  return byPath;
}

/// What Undo can do for a file the turn changed with `diffs` (in order).
export function fileUndo(diffs: readonly AcpmuxFileDiff[]): FileUndo {
  const first = diffs[0];
  const last = diffs[diffs.length - 1];
  // The host takes absolute paths only; a path as the agent wrote it (`~/x`, `src/x`) is not one.
  if (!first || !last || !first.path.startsWith("/")) return { kind: "cannot" };
  for (let index = 1; index < diffs.length; index++)
    if (diffs[index]!.oldText !== diffs[index - 1]!.newText) return { kind: "cannot" };
  // An empty result could be a replace-all of a fragment: the original is not known.
  if (last.newText === "" && diffs.some((diff) => diff.oldText)) return { kind: "cannot" };
  if (first.oldText === undefined) return { kind: "trash", after: last.newText };
  return { kind: "revert", before: first.oldText, after: last.newText };
}

/// The card's files: `counts` (the display's paths and line counts) with each file's Undo.
export function turnChanges(
  turnId: string,
  rows: readonly AcpmuxRow[],
  counts: readonly { path: string; additions: number; deletions: number }[],
): TurnChanges {
  const byPath = diffsByPath(rows);
  return {
    turnId,
    files: counts.map((file) => ({
      path: file.path,
      added: file.additions,
      removed: file.deletions,
      undo: fileUndo(byPath.get(file.path) ?? []),
    })),
  };
}

/// One file of a `turn.undo` request.
export type UndoFileParam = { path: string; before: string | null; after: string };

/// The `turn.undo` files of the ones Undo can do.
export function undoFiles(files: readonly EditedFile[]): UndoFileParam[] {
  return files.flatMap((file): UndoFileParam[] => {
    if (file.undo.kind === "revert") return [{ path: file.path, before: file.undo.before, after: file.undo.after }];
    if (file.undo.kind === "trash") return [{ path: file.path, before: null, after: file.undo.after }];
    return [];
  });
}

/// The host's answer for one file (Swift AgentPaneTurnUndo.Status).
export type UndoStatus =
  | "reverted"
  | "trashed"
  | "wouldRevert"
  | "wouldTrash"
  | "changed"
  | "cannotUndo"
  | "outsideRoots";

const STATUSES = new Set<string>([
  "reverted",
  "trashed",
  "wouldRevert",
  "wouldTrash",
  "changed",
  "cannotUndo",
  "outsideRoots",
]);

/// The host's `{files: [{path, status}]}`; an unknown status reads as cannotUndo.
export function readUndoReply(value: unknown): Map<string, UndoStatus> {
  const files = (value && typeof value === "object" ? (value as { files?: unknown }).files : undefined) ?? [];
  const statuses = new Map<string, UndoStatus>();
  if (!Array.isArray(files)) return statuses;
  for (const entry of files) {
    if (!entry || typeof entry !== "object") continue;
    const { path, status } = entry as { path?: unknown; status?: unknown };
    if (typeof path !== "string") continue;
    statuses.set(path, typeof status === "string" && STATUSES.has(status) ? (status as UndoStatus) : "cannotUndo");
  }
  return statuses;
}

/// What the confirmation says before anything is written: files Undo will put back, files that
/// changed since the turn, and edits it cannot undo.
export function undoSummary(files: readonly EditedFile[], dryRun: ReadonlyMap<string, UndoStatus>) {
  let undo = 0;
  let changed = 0;
  let cannot = 0;
  for (const file of files) {
    const status = dryRun.get(file.path);
    if (status === "wouldRevert" || status === "wouldTrash") undo += 1;
    else if (status === "changed") changed += 1;
    else cannot += 1;
  }
  return { undo, changed, cannot };
}
