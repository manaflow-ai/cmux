// A turn's changes as its before/after checkpoint pair records them, when the host has one, or
// else as the turn's tool calls report them. The checkpoint diff is the truth on disk: it holds
// a file once with its net change, and it holds changes no tool call made (a shell command, a
// formatter). Those are shown read-only; hunks that still match a tool edit carry its review key
// so Keep and Undo stay connected to the tool call that produced them.
import { hunkKey, type DiffHunk, type PathRef, type TurnFile } from "../diff";
import { currentLanguage, translatorFor, type Translate } from "../i18n";
import { pathKey } from "../model";
import { changeSetFiles, readChangeSet, type ChangeSet } from "./model";

/// The host's answer for one turn: a checkpoint pair's diff in `git.diff`'s shape, or null when
/// the turn has no pair. `complete: false` means files were left out of a checkpoint.
/// `unsupported` means the agent records no checkpoints, so the tool-call view is the only one.
export type TurnCheckpointWire =
  | {
      checkpoint_id: string;
      complete: boolean;
      diff: unknown;
    }
  | { unsupported: true }
  | null;

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
  if (raw.unsupported === true) return { state: "unsupported" };
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
  /// The loaded checkpoint left files out (`filesOmitted`, `untrackedSkipped`), so the view lists
  /// only part of the change.
  partial?: true;
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
  // A suffix match (no canonical path) can represent two path aliases for one physical file;
  // mapping to the first one could leave the other tool edit unreviewed.
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

/// A checkpoint file is one a tool call changed when their canonical paths are the same (model.ts
/// `pathKey`; a loaded checkpoint's is `${root}/${path}`, `checkpointFiles`). Without both, by the
/// path as the agent wrote it: when a tool call's path is it, or ends with its path under the
/// repository (`~/code/x/a.ts`).
export function changedByTools(
  file: Pick<TurnFile, "path" | "displayPath" | "canonical">,
  toolFiles: readonly PathRef[],
) {
  return toolFiles.some((tool) =>
    tool.canonical && file.canonical
      ? tool.canonical === file.canonical
      : tool.path === file.path || tool.path.endsWith(`/${file.displayPath}`),
  );
}

/// Whether a tool call's path is checkpoint `file` of the repository at `root`, more strictly than
/// `changedByTools`. With both canonical paths, when they are the same. Without, under the root, the
/// same path from it (docs/notes.txt is not notes.txt); outside it, the same path from the root's own
/// folder, so /tmp/repo/notes.txt is a repository at /private/tmp/repo's notes.txt and ~/code/x/a.ts
/// is x's a.ts, but /elsewhere/notes.txt is not. A listed file outside the repository (a /tmp file,
/// named from another folder) is only its own path.
export function namesCheckpointFile(
  { path, canonical }: PathRef,
  file: Pick<TurnFile, "path" | "displayPath" | "canonical">,
  root: string | undefined,
) {
  if (canonical && file.canonical) return canonical === file.canonical;
  if (path === file.path) return true;
  const top = root?.replace(/\/+$/, "");
  if (top === undefined) return changedByTools(file, [{ path }]);
  if (file.path.startsWith("/") && !file.path.startsWith(`${top}/`)) return false;
  if (path.startsWith(`${top}/`)) return path.slice(top.length + 1) === file.displayPath;
  return path.endsWith(`/${top.slice(top.lastIndexOf("/") + 1)}/${file.displayPath}`);
}

/// The tool calls' files at an absolute path outside the repository at `root`, which no checkpoint
/// of it holds, by their canonical paths when acpmux recorded them. A relative path is the agent's,
/// under its folder, so it stays with the checkpoint, and so does a file a checkpoint file already
/// matches (`changedByTools`), such as /tmp/x for a repository under /private/tmp, so no file lists
/// twice. The edited-files card reads its paths without counts the same way.
export function outsideRepository<File extends PathRef>(
  toolFiles: readonly File[],
  root: string | undefined,
  checkpointFiles: readonly Pick<TurnFile, "path" | "displayPath" | "canonical">[],
): File[] {
  const top = root?.replace(/\/+$/, "");
  if (top === undefined) return [];
  // A canonical path is composed (NFC); git prints the root as stored, which may be decomposed.
  const under = (file: File) =>
    file.canonical ? file.canonical.startsWith(`${top.normalize("NFC")}/`) : file.path.startsWith(`${top}/`);
  return toolFiles.filter((file) => {
    const key = pathKey(file);
    return (
      key.startsWith("/") &&
      !under(file) &&
      !checkpointFiles.some((checkpointFile) => changedByTools(checkpointFile, [file]))
    );
  });
}

/// A loaded checkpoint's files, each with its canonical path: `${root}/${path}` as git names the
/// repository (`rev-parse --show-toplevel`, its real path), composed (NFC) as acpmux's canonical
/// paths are: git prints names as stored, and a folder created decomposed stays so.
function checkpointFiles(changeSet: ChangeSet): TurnFile[] {
  const files = changeSetFiles(changeSet);
  return changeSet.root ? files.map((file) => ({ ...file, canonical: file.path.normalize("NFC") })) : files;
}

/// What the Last turn view shows. A checkpoint that loads replaces the tool calls' edits, unless
/// Keep or Undo choices on those edits are still unsent: the view switches once they are sent
/// or cleared, so no choice moves under the reader's hand. `pathsOnly`: paths the tool calls changed
/// without a diff (diff.ts `turnPathsOnly`), so a checkpoint file there is not marked `outside`.
export function turnDisplay(
  t: Translate,
  toolFiles: TurnFile[],
  load: TurnCheckpointLoad,
  pending: boolean,
  pathsOnly: readonly PathRef[] = [],
): TurnDisplay {
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
      // The checkpoint left files out, so the turn's changes are only partly known.
      return { ...tools(t("turn.checkpoint.incomplete")), partial: true };
    case "loaded": {
      // The checkpoint left files out (`filesOmitted`, `untrackedSkipped`): the view lists only part
      // of the change, whichever view shows.
      const partial = (load.changeSet.filesOmitted ?? 0) > 0 || (load.changeSet.untrackedSkipped ?? 0) > 0;
      if (pending) {
        const display = tools(t("turn.checkpoint.pending"));
        return partial ? { ...display, partial: true } : display;
      }
      const changed = [...toolFiles, ...pathsOnly];
      const files = checkpointFiles(load.changeSet).map((file) => {
        const reviewFile = checkpointReviewFile(file, toolFiles);
        return {
          ...reviewFile,
          edits: reviewFile.edits.map((edit) => ({ ...edit, toolId: `checkpoint:${load.checkpointId}` })),
          ...(changedByTools(file, changed) ? {} : { outside: true }),
        };
      });
      // The checkpoint holds only its repository: a file a tool call wrote elsewhere (a new file in
      // /tmp) keeps its tool-call diff, or it would vanish from the card and the view.
      return {
        files: [...files, ...outsideRepository(toolFiles, load.changeSet.root, files)],
        source: "checkpoint",
        ...(partial ? { partial: true as const } : {}),
      };
    }
  }
}

/// The edited-files card's totals: the checkpoint's once it has loaded, else the tool calls'.
/// `root`: the loaded checkpoint's repository. `pathsOnly` as for `turnDisplay`.
export function turnCounts(
  toolFiles: readonly TurnFile[],
  load: TurnCheckpointLoad | undefined,
  pathsOnly: readonly PathRef[] = [],
) {
  const display =
    load?.state === "loaded"
      ? turnDisplay(translatorFor(currentLanguage()), [...toolFiles], load, false, pathsOnly)
      : undefined;
  const files = display?.files ?? toolFiles;
  return {
    files,
    root: load?.state === "loaded" ? load.changeSet.root : undefined,
    additions: files.reduce((sum, file) => sum + file.additions, 0),
    deletions: files.reduce((sum, file) => sum + file.deletions, 0),
    outside: files.some((file) => file.outside),
  };
}
