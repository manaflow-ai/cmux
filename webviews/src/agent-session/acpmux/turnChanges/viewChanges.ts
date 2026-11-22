// Where an edited-files card's View changes opens. The chat folder's diff opens in its own pane
// beside the chat (App.tsx `diffBeside`), but that is the folder's git diff: it shows nothing for a
// folder that is not a repository (the viewer asks for one instead), nor a file the turn wrote outside
// the repository (a new /tmp/l-setup.txt). Such a turn's diff tab shows the turn's own patch instead,
// built from the tool calls (`viewChangesPatch`), which shows any file. Either way it is a tab on the
// chat's right, never a view over the chat (Leo, 2026-11-03: "the diff thing/changes viewer still
// doesn't open up on the right pane? why? just put it in a tab???").
import { editPatch, turnFiles, turnPathsOnly, turnRows, type TurnFile } from "../diff";
import type { AcpmuxRow } from "../model";
import { readTurnCheckpoint, turnDisplay } from "../changes/turnCheckpoint";
import { readTurnFromRows, turnCheckpointPair, type CheckpointDiff } from "../changes/turnCheckpointSource";
import { currentLanguage, translatorFor } from "../i18n";

/// The top level of the repository holding `folder`, from the host's `git.status` for it
/// (GitStatusResult `root`); undefined when the folder is not in one or the read fails.
export async function repositoryRoot(
  folder: string,
  readStatus: (cwd: string) => Promise<unknown>,
): Promise<string | undefined> {
  const status = await readStatus(folder).catch(() => undefined);
  const root = status && typeof status === "object" ? (status as { root?: unknown }).root : undefined;
  return typeof root === "string" && root.startsWith("/") ? root.replace(/\/+$/, "") || "/" : undefined;
}

/// Whether the chat header's Changes opens the last turn's own changes (its patch tab, or the page's
/// view where no tab can open), not the folder's diff tab: the chat's folder (`folder`, on the chat's
/// machine) is in no repository, so that tab would have nothing to show and the app would ask for a
/// folder in the palette instead. A diff tab Changes already opened (`open`) closes through the app as
/// before.
export async function headerChangesInPlace(
  folder: string | undefined,
  open: boolean,
  readStatus: (cwd: string) => Promise<unknown>,
): Promise<boolean> {
  if (!folder || open) return false;
  return (await repositoryRoot(folder, readStatus)) === undefined;
}

/// Whether the turn holding `rowId` opens in the chat folder's diff beside the chat: the folder is in
/// a repository (`root`, from `repositoryRoot`) and every file the turn's tool calls changed lies in
/// it. A relative path is the agent's, under its folder; a `~` path cannot be placed, so it counts as
/// elsewhere.
export function viewChangesBeside(rows: readonly AcpmuxRow[], rowId: string, root: string | undefined): boolean {
  if (!root) return false;
  const top = root === "/" ? "" : root;
  return turnFiles(turnRows([...rows], rowId)).every((file) =>
    file.path.startsWith("/") ? file.path.startsWith(`${top}/`) : !file.path.startsWith("~"),
  );
}

/// The turn the diff tab opens on (D1, `pane.action {id: "openDiffViewer", turn}`): the checkpoint
/// pair, the edited file it scrolls to, and `show` (open on the turn, or only offer it as Last turn).
export type DiffTabTurn = { from: string; to: string; file?: string; show: boolean };

/// The diff tab's turn for the turn holding `rowId`, at `path` (an edited-files row) when given:
/// undefined when the turn has no checkpoint pair (an agent that records none), and the tab then
/// opens the folder's diff as before. `root` is the repository's, `cwd` the chat's folder.
export function viewChangesTurn(
  rows: readonly AcpmuxRow[],
  rowId: string,
  path: string | undefined,
  root: string,
  cwd: string,
): DiffTabTurn | undefined {
  const pair = turnCheckpointPair(rows, rowId);
  if (!pair) return undefined;
  const file = path === undefined ? undefined : repositoryFile(path, root, cwd);
  return { ...pair, ...(file ? { file } : {}), show: true };
}

/// `path` as a path in the repository at `root`: an absolute path under it, or a path from the
/// agent's folder `cwd`; undefined for a path outside it or written from `~`.
export function repositoryFile(path: string, root: string, cwd: string): string | undefined {
  const top = root === "/" ? "" : root.replace(/\/+$/, "");
  if (path.startsWith("~")) return undefined;
  let absolute = path;
  if (!path.startsWith("/")) absolute = `${cwd.replace(/\/+$/, "")}/${path}`;
  const parts: string[] = [];
  for (const part of absolute.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return undefined;
      parts.pop();
    } else parts.push(part);
  }
  const normal = `/${parts.join("/")}`;
  // git names the root with links resolved: a chat in /tmp/app has its repository at /private/tmp/app.
  for (const candidate of [normal, `/private${normal}`]) {
    if (candidate.startsWith(`${top}/`) && candidate.length > top.length + 1) return candidate.slice(top.length + 1);
  }
  return undefined;
}

/// The turn's own changes the diff tab shows (`pane.action {id: "openDiffViewer", patch}`): unified
/// patch text and the patch's name of the file the tab scrolls to.
export type DiffTabPatch = { text: string; file?: string };

/// The longest patch the app takes (AgentPaneDiffPatch.maximumBytes); a longer one shows in the page.
const MAX_PATCH_BYTES = 16 << 20;

/// The files the turn holding `rowId` changed, as the page's own Last turn view shows them: its
/// checkpoint pair's diff when the session host has one (which also holds what no tool call made, a
/// shell command or a formatter), with the tool calls' edits to files outside the repository beside
/// it; else the tool calls' edits alone (turnCheckpoint.ts `turnDisplay`).
export async function viewChangesFiles(
  rows: readonly AcpmuxRow[],
  rowId: string,
  diff: CheckpointDiff,
): Promise<TurnFile[]> {
  const turn = turnRows([...rows], rowId);
  const tools = turnFiles(turn);
  const load = await readTurnFromRows(rows, rowId, diff).then(readTurnCheckpoint, () => ({ state: "error" as const }));
  return turnDisplay(translatorFor(currentLanguage()), tools, load, false, turnPathsOnly(turn)).files;
}

/// `files` (``viewChangesFiles``, else the turn's tool-call edits) as a `DiffTabPatch`, at the file
/// `path` names (an edited-files row). A file under the chat's folder `cwd` is named from it, any
/// other by its full path. Each edit is its own file section, as the page's own changes view lists
/// them: two edits' line numbers count from different versions of the file, so one section could
/// not hold both. Undefined when nothing changed the patch can show, or it is too long.
export function viewChangesPatch(
  rows: readonly AcpmuxRow[],
  rowId: string,
  path: string | undefined,
  cwd: string | undefined,
  files: readonly TurnFile[] = turnFiles(turnRows([...rows], rowId)),
): DiffTabPatch | undefined {
  let text = "";
  let file: string | undefined;
  for (const changed of files) {
    const name = patchName(changed.path, cwd);
    if (path !== undefined && (changed.path === path || changed.canonical === path)) file = name;
    const shown = changed.edits.filter((edit) => edit.hunks.length > 0);
    for (const edit of shown) text += editPatch({ ...changed, displayPath: name }, edit);
    // A file with no text hunks (binary, or an empty file made or removed) still lists, by its git
    // header alone, as the page's own view lists it.
    if (shown.length === 0) text += headerPatch(changed, name);
  }
  if (!text || new TextEncoder().encode(text).length > MAX_PATCH_BYTES) return undefined;
  return file === undefined ? { text } : { text, file };
}

/// A file's git header with no hunks: its name, whether it was made or removed, and git's line for
/// a binary file.
function headerPatch(file: TurnFile, name: string): string {
  const lines = [`diff --git a/${name} b/${name}`];
  if (file.created) lines.push("new file mode 100644");
  else if (file.deleted) lines.push("deleted file mode 100644");
  if (file.binary) {
    const from = file.created ? "/dev/null" : `a/${name}`;
    const to = file.deleted ? "/dev/null" : `b/${name}`;
    lines.push(`Binary files ${from} and ${to} differ`);
  }
  return `${lines.join("\n")}\n`;
}

/// `path` as the patch names it: from the chat's folder when it is under it, else the full path
/// (a leading `/` kept, so `/tmp/x` reads as itself); `~` paths as the agent wrote them.
export function patchName(path: string, cwd: string | undefined): string {
  const top = cwd?.replace(/\/+$/, "");
  if (top && path.startsWith(`${top}/`) && path.length > top.length + 1) return path.slice(top.length + 1);
  return path;
}
