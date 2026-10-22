// Where an edited-files card's View changes opens. The chat folder's diff opens in its own pane
// beside the chat (App.tsx `diffBeside`), but that is the folder's git diff: it shows nothing for a
// folder that is not a repository (the viewer asks for one instead), nor a file the turn wrote outside
// the repository (a new /tmp/l-setup.txt). Such a turn opens its own diff in the page instead, built
// from the tool calls, which shows any file. Outside Quick Chat that diff opens beside the chat too, in
// the same diff viewer, as a patch (`besideRequest`).
import { turnFiles, turnPatch, turnRows } from "../diff";
import type { AcpmuxRow } from "../model";

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

/// The longest turn patch sent to the App (UTF-16 units); a larger turn opens its diff in the page.
export const TURN_PATCH_LIMIT = 8 * 1024 * 1024;

/// What View changes asks the App to open beside the chat (`pane.action` `openDiffViewer`), or
/// undefined when the turn's diff opens in the page:
/// - `{cwd}`: the chat folder's diff, when `viewChangesBeside` holds;
/// - `{patch, title}`: else the turn's own diff (`turnPatch`), in the same viewer (Leo, 2026-10-22: "why's
///   the diff viewer not opening up in the right split tab? what about the existing diff viewer
///   elsewhere that was previously made?"), titled `title`; undefined when the turn has no hunk to
///   show or its patch passes `TURN_PATCH_LIMIT`.
export function besideRequest(
  rows: readonly AcpmuxRow[],
  rowId: string,
  folder: string | undefined,
  root: string | undefined,
  title: string,
): { cwd: string } | { patch: string; title: string } | undefined {
  if (folder && viewChangesBeside(rows, rowId, root)) return { cwd: folder };
  const patch = turnPatch(turnFiles(turnRows([...rows], rowId)));
  return patch && patch.length <= TURN_PATCH_LIMIT ? { patch, title } : undefined;
}
