// Where an edited-files card's View changes opens. The chat folder's diff opens in its own pane
// beside the chat (App.tsx `diffBeside`), but that is the folder's git diff: a file the turn wrote
// outside the folder (a new /tmp/l-setup.txt) is not in it. Such a turn opens its own diff in the
// page instead, built from the tool calls, which shows any file.
import { turnFiles, turnRows } from "../diff";
import type { AcpmuxRow } from "../model";

/// Whether the turn holding `rowId` opens in the chat folder's diff beside the chat: the chat has a
/// folder on this Mac and every file the turn's tool calls changed lies in it. A relative path is the
/// agent's, under its folder; a `~` path cannot be placed, so it counts as elsewhere.
export function viewChangesBeside(rows: readonly AcpmuxRow[], rowId: string, folder: string | undefined): boolean {
  if (!folder) return false;
  const top = folder.replace(/\/+$/, "");
  return turnFiles(turnRows([...rows], rowId)).every((file) =>
    file.path.startsWith("/") ? file.path.startsWith(`${top}/`) : !file.path.startsWith("~"),
  );
}
