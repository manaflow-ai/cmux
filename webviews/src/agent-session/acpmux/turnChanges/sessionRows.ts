// The session's edited-files rows, for the edited-files card's session scope
// (`agentPane.editedFiles.scope` session): the card at the latest edit covers every edit of the
// session. The pane provides them, the same array until an edit row changes, so a card's memos
// survive the snapshots of a long chat.
import { createContext } from "react";
import { isFoldedCopy } from "../conversation/turns";
import type { AcpmuxRow } from "../model";

export const SessionEditsContext = createContext<readonly AcpmuxRow[] | undefined>(undefined);

const editRows = new WeakMap<AcpmuxRow, boolean>();

/// The edit rows of `rows`, oldest first; `previous` when they are the same rows.
export function sessionEdits(rows: readonly AcpmuxRow[], previous?: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const edits: AcpmuxRow[] = [];
  for (const row of rows) {
    let edit = editRows.get(row);
    if (edit === undefined) editRows.set(row, (edit = isEditRow(row)));
    if (edit) edits.push(row);
  }
  return previous && previous.length === edits.length && previous.every((row, index) => row === edits[index])
    ? previous
    : edits;
}

/// A row the transcript draws as an edited-files card (App.tsx `rowKind`).
export function isEditRow(row: AcpmuxRow): boolean {
  return (
    row.kind === "activity" &&
    !isFoldedCopy(row) &&
    (row.items ?? []).some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange")
  );
}
