// A turn's changes as its before/after checkpoint pair records them, when the host has one, or
// else as the turn's tool calls report them. The checkpoint diff is the truth on disk: it holds
// a file once with its net change, and it holds changes no tool call made (a shell command, a
// formatter). Those are shown read-only; Keep and Undo stay on the files the tool calls changed.
import type { TurnFile } from "../diff";
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
      const files = changeSetFiles(load.changeSet).map((file) => ({
        ...file,
        edits: file.edits.map((edit) => ({ ...edit, toolId: `checkpoint:${load.checkpointId}` })),
        ...(changedByTools(file, toolFiles) ? {} : { outside: true }),
      }));
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
