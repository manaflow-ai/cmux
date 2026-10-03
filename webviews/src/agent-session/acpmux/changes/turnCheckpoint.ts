// A turn's changes as its before/after checkpoint pair records them, when the host has one, or
// else as the turn's tool calls report them. The checkpoint diff is the truth on disk: it holds
// a file once with its net change, and it holds changes no tool call made (a shell command, a
// formatter). Those are shown read-only; Keep and Undo stay on the files the tool calls changed.
import { checkpointHunkKey, hunkKey, hunkRange, type DiffHunk, type TurnFile } from "../diff";
import { t } from "../i18n";
import { changeSetFiles, readChangeSet, type ChangeSet } from "./model";

/// The host's answer for one turn: a checkpoint pair's diff in `git.diff`'s shape, or null when
/// the turn has no pair. `complete: false` means files were left out of a checkpoint.
export type TurnCheckpointWire = {
  checkpoint_id: string;
  complete: boolean;
  diff: unknown;
} | null;

export type TurnCheckpointLoad =
  /// The host keeps no per-turn checkpoints, so the tool-call view is the only one.
  | { state: "unsupported" }
  | { state: "loading" }
  /// The host keeps them, but not for this turn.
  | { state: "missing" }
  | { state: "error"; message?: string }
  | { state: "incomplete"; checkpointId: string }
  | { state: "loaded"; checkpointId: string; changeSet: ChangeSet };

export function readTurnCheckpoint(value: unknown): TurnCheckpointLoad {
  if (value === null) return { state: "missing" };
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const checkpointId = typeof raw.checkpoint_id === "string" ? raw.checkpoint_id : undefined;
  const changeSet = readChangeSet(raw.diff, "lastTurn");
  if (!checkpointId || !changeSet) return { state: "error" };
  if (raw.complete !== true) return { state: "incomplete", checkpointId };
  return { state: "loaded", checkpointId, changeSet };
}

export type TurnDisplay = {
  files: TurnFile[];
  source: "checkpoint" | "tools";
  /// Why the tool-call view shows when a checkpoint was expected.
  note?: string;
};

/// A checkpoint file is one a tool call changed when a tool call's path is it, or ends with its
/// path under the repository: tool calls report paths as the agent wrote them (`~/code/x/a.ts`).
export function changedByTools(file: TurnFile, toolFiles: readonly TurnFile[]) {
  return toolFiles.some((tool) => tool.path === file.path || tool.path.endsWith(`/${file.displayPath}`));
}

type ReviewCandidate = { key: string; hunk: DiffHunk; changed: Set<string> };

function changedTokens(hunk: DiffHunk): Set<string> {
  return new Set(hunk.lines.filter((line) => line.type !== "context").map((line) => `${line.type}\u0000${line.text}`));
}

function changedLines(hunk: DiffHunk, side: "old" | "new"): number[] {
  const key = side === "old" ? "oldLine" : "newLine";
  return hunk.lines.flatMap((line) => (line.type !== "context" && line[key] !== undefined ? [line[key]!] : []));
}

function overlap(a: readonly number[], b: readonly number[]): number {
  if (!a.length || !b.length) return 0;
  const wanted = new Set(b);
  return a.filter((line) => wanted.has(line)).length;
}

/// Finds the tool hunks that still own a checkpoint hunk. Line overlap disambiguates repeated
/// edits with identical text; changed-line tokens keep bare tool fragments attributable when the
/// tool did not report locations. A checkpoint hunk with no match stays read-only.
function checkpointReviewKeys(file: TurnFile, hunk: DiffHunk, toolFile: TurnFile | undefined): string[] {
  if (!toolFile) return [];
  const wanted = changedTokens(hunk);
  if (!wanted.size) return [];
  const oldLines = changedLines(hunk, "old");
  const newLines = changedLines(hunk, "new");
  const candidates: ReviewCandidate[] = toolFile.edits.flatMap((edit, editIndex) =>
    edit.hunks.map((toolHunk, hunkIndex) => ({
      key: hunkKey(toolFile, editIndex, hunkIndex),
      hunk: toolHunk,
      changed: changedTokens(toolHunk),
    })),
  );
  const scored = candidates.map((candidate) => {
    const tokens = [...wanted].filter((token) => candidate.changed.has(token)).length;
    const lines =
      overlap(newLines, changedLines(candidate.hunk, "new")) + overlap(oldLines, changedLines(candidate.hunk, "old"));
    const contentMatches = tokens === candidate.changed.size || tokens === wanted.size;
    return { candidate, score: contentMatches ? tokens * 100 + lines * 10 : 0 };
  });
  const best = Math.max(0, ...scored.map(({ score }) => score));
  return best ? scored.filter(({ score }) => score === best).map(({ candidate }) => candidate.key) : [];
}

function checkpointReviewFile(file: TurnFile, checkpointId: string, toolFiles: readonly TurnFile[]): TurnFile {
  const toolFile = toolFiles.find((candidate) => changedByTools(file, [candidate]));
  return {
    ...file,
    edits: file.edits.map((edit) => ({
      ...edit,
      hunks: edit.hunks.map((hunk) => ({
        ...hunk,
        reviewKeys: checkpointReviewKeys(file, hunk, toolFile),
        checkpoint: {
          id: checkpointId,
          path: file.path,
          range: hunkRange(hunk),
          key: checkpointHunkKey(checkpointId, file.path, hunk),
        },
      })),
    })),
  };
}

/// What the Last turn view shows. A checkpoint that loads replaces the tool calls' edits, unless
/// Keep or Undo choices on those edits are still unsent: the view switches once they are sent
/// or cleared, so no choice moves under the reader's hand.
export function turnDisplay(toolFiles: TurnFile[], load: TurnCheckpointLoad, pending: boolean): TurnDisplay {
  const tools = (note?: string): TurnDisplay => ({ files: toolFiles, source: "tools", note });
  switch (load.state) {
    case "unsupported":
    case "loading":
      return tools();
    case "missing":
      return tools(t("turn.checkpoint.missing"));
    case "error":
      return tools(t("turn.checkpoint.failed"));
    case "incomplete":
      return tools(t("turn.checkpoint.incomplete"));
    case "loaded": {
      if (pending) return tools(t("turn.checkpoint.pending"));
      const files = changeSetFiles(load.changeSet).map((file) => {
        const reviewFile = checkpointReviewFile(file, load.checkpointId, toolFiles);
        return {
          ...reviewFile,
          edits: reviewFile.edits.map((edit) => ({
            ...edit,
            toolId: `checkpoint:${load.checkpointId}`,
            hunks: edit.hunks.map((hunk) => ({
              ...hunk,
              checkpoint: {
                id: load.checkpointId,
                path: file.path,
                range: hunkRange(hunk),
                key: checkpointHunkKey(load.checkpointId, file.path, hunk),
              },
            })),
          })),
          ...(changedByTools(file, toolFiles) ? {} : { outside: true }),
        };
      });
      return { files, source: "checkpoint" };
    }
  }
}

/// The edited-files card's totals: the checkpoint's once it has loaded, else the tool calls'.
export function turnCounts(toolFiles: readonly TurnFile[], load: TurnCheckpointLoad | undefined) {
  const display = load?.state === "loaded" ? turnDisplay([...toolFiles], load, false) : undefined;
  const files = display?.files ?? toolFiles;
  return {
    files,
    additions: files.reduce((sum, file) => sum + file.additions, 0),
    deletions: files.reduce((sum, file) => sum + file.deletions, 0),
    outside: files.some((file) => file.outside),
  };
}
