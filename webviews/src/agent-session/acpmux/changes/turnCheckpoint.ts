// A turn's changes as its before/after checkpoint pair records them, when the host has one, or
// else as the turn's tool calls report them. The checkpoint diff is the truth on disk: it holds
// a file once with its net change, and it holds changes no tool call made (a shell command, a
// formatter). Those are shown read-only; hunks that still match a tool edit carry its review key
// so Keep and Undo stay connected to the tool call that produced them.
import { hunkKey, type DiffHunk, type TurnFile } from "../diff";
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

type ReviewCandidate = { key: string; changed: Map<string, number>; lines: Set<number> };

function changedTokens(hunk: DiffHunk): Map<string, number> {
  const tokens = new Map<string, number>();
  for (const line of hunk.lines) {
    if (line.type === "context") continue;
    const token = line.type + "\u0000" + line.text;
    tokens.set(token, (tokens.get(token) ?? 0) + 1);
  }
  return tokens;
}

function sameTokens(left: ReadonlyMap<string, number>, right: ReadonlyMap<string, number>): boolean {
  if (left.size !== right.size) return false;
  return [...left].every(([token, count]) => right.get(token) === count);
}

function changedLines(hunk: DiffHunk): Set<number> {
  return new Set(
    hunk.lines.flatMap((line) => {
      if (line.type === "context") return [];
      const number = line.type === "add" ? line.newLine : line.oldLine;
      return number === undefined ? [] : [number];
    }),
  );
}

function checkpointReviewKeys(file: TurnFile, hunk: DiffHunk, toolFile: TurnFile | undefined): string[] {
  if (!toolFile || file.patchTruncated) return [];
  const wanted = changedTokens(hunk);
  if (wanted.size === 0) return [];
  const wantedLines = changedLines(hunk);
  const candidates: ReviewCandidate[] = toolFile.edits.flatMap((edit, editIndex) =>
    edit.hunks.map((toolHunk, hunkIndex) => ({
      key: hunkKey(toolFile, editIndex, hunkIndex),
      changed: changedTokens(toolHunk),
      lines: changedLines(toolHunk),
    })),
  );
  const chosen = new Set<string>();
  for (const [token, count] of wanted) {
    const matches = candidates.filter(
      (candidate) =>
        (candidate.changed.get(token) ?? 0) >= count &&
        (wantedLines.size === 0 ||
          candidate.lines.size === 0 ||
          [...wantedLines].some((line) => candidate.lines.has(line))),
    );
    // Every changed token must identify one tool hunk. If a repeated token is shared by hunks,
    // or its numbered location differs, leave the checkpoint hunk read-only.
    if (matches.length !== 1) return [];
    chosen.add(matches[0]!.key);
  }
  const covered = new Map<string, number>();
  for (const candidate of candidates.filter((candidate) => chosen.has(candidate.key))) {
    for (const [token, count] of candidate.changed) covered.set(token, (covered.get(token) ?? 0) + count);
  }
  return sameTokens(wanted, covered) ? [...chosen] : [];
}

function checkpointReviewFile(file: TurnFile, toolFiles: readonly TurnFile[]): TurnFile {
  const matchingToolFiles = toolFiles.filter((candidate) => changedByTools(file, [candidate]));
  // A suffix match can represent two path aliases for one physical file. Without a canonical
  // identity, mapping to the first one could leave the other tool edit unreviewed.
  const toolFile = matchingToolFiles.length === 1 ? matchingToolFiles[0] : undefined;
  return {
    ...file,
    edits: file.edits.map((edit) => ({
      ...edit,
      hunks: edit.hunks.map((hunk) => ({
        ...hunk,
        reviewKeys: checkpointReviewKeys(file, hunk, toolFile),
      })),
    })),
  };
}

/// A checkpoint file is one a tool call changed when a tool call's path is it, or ends with its
/// path under the repository: tool calls report paths as the agent wrote them (`~/code/x/a.ts`).
export function changedByTools(file: TurnFile, toolFiles: readonly TurnFile[]) {
  return toolFiles.some((tool) => tool.path === file.path || tool.path.endsWith(`/${file.displayPath}`));
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
        const reviewFile = checkpointReviewFile(file, toolFiles);
        return {
          ...reviewFile,
          edits: reviewFile.edits.map((edit) => ({ ...edit, toolId: `checkpoint:${load.checkpointId}` })),
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
