// Where an edited-files card's View changes opens. The chat folder's diff opens in its own pane
// beside the chat (App.tsx `diffBeside`), but that is the folder's git diff: it shows nothing for a
// folder that is not a repository (the viewer asks for one instead), nor a file the turn wrote outside
// the repository (a new /tmp/l-setup.txt). Such a turn opens its own diff in the page instead, built
// from the tool calls, which shows any file.
import { turnFiles, turnRows } from "../diff";
import type { AcpmuxRow } from "../model";
import { turnCheckpointPair } from "../changes/turnCheckpointSource";

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
