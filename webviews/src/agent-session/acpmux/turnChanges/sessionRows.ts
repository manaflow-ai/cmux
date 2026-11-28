// The transcript's rows, for the edited-files card's session scope (`agentPane.editedFiles.scope`
// session): the card at the latest edit covers every edit of the session. The pane provides them.
import { createContext } from "react";
import { isFoldedCopy } from "../conversation/turns";
import type { AcpmuxRow } from "../model";

export const SessionRowsContext = createContext<readonly AcpmuxRow[] | undefined>(undefined);

/// A row the transcript draws as an edited-files card (App.tsx `rowKind`).
export function isEditRow(row: AcpmuxRow): boolean {
  return (
    row.kind === "activity" &&
    !isFoldedCopy(row) &&
    (row.items ?? []).some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange")
  );
}
