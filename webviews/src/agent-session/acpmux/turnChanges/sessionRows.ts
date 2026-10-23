// The session's edited-files rows, for the edited-files card's session scope
// (`agentPane.editedFiles.scope` session): the card at the latest edit covers every edit of the
// session. The pane provides them, the same array until an edit row changes, so a card's memos
// survive the snapshots of a long chat.
import { createContext } from "react";
import { isFoldedCopy } from "../conversation/turns";
import type { AcpmuxRow } from "../model";

export const SessionEditsContext = createContext<readonly AcpmuxRow[] | undefined>(undefined);

const editRows = new WeakMap<AcpmuxRow, boolean>();

/// A session's edit rows (`edits`, oldest first) and where each is in `rows`.
export type SessionEdits = { rows: readonly AcpmuxRow[]; at: number[]; edits: readonly AcpmuxRow[] };

/// The edit rows of `rows`. Rows before the first that differs from `previous.rows` (by object)
/// keep their result, and `edits` stays `previous.edits` when they are the same rows.
export function sessionEdits(rows: readonly AcpmuxRow[], previous?: SessionEdits): SessionEdits {
  let from = 0;
  if (previous)
    while (from < rows.length && from < previous.rows.length && rows[from] === previous.rows[from]) from += 1;
  let keep = 0;
  if (previous) while (keep < previous.at.length && previous.at[keep]! < from) keep += 1;
  const at = previous ? previous.at.slice(0, keep) : [];
  const edits = previous ? previous.edits.slice(0, keep) : [];
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    let edit = editRows.get(row);
    if (edit === undefined) editRows.set(row, (edit = isEditRow(row)));
    if (edit) {
      at.push(index);
      edits.push(row);
    }
  }
  const same =
    previous && previous.edits.length === edits.length && previous.edits.every((row, index) => row === edits[index]);
  return { rows, at, edits: same ? previous.edits : edits };
}

/// A row the transcript draws as an edited-files card (App.tsx `rowKind`). An edit still waiting
/// for its permission has not run, so it reads as its tool call until then. A shaped tool run
/// (`foldRun`, including false while permission is pending) also keeps its tool-row renderer.
export function isEditRow(row: AcpmuxRow): boolean {
  return (
    row.kind === "activity" &&
    row.foldRun === undefined &&
    !isFoldedCopy(row) &&
    (row.items ?? []).some(
      (item) => (item.tool?.kind === "edit" || item.tool?.kind === "fileChange") && item.tool.status !== "pending",
    )
  );
}

/// The session's folder, so a tool row names a file in it by its path from there. The pane provides it.
export const SessionCwdContext = createContext<string | undefined>(undefined);
