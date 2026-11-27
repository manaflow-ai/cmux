// The session's edited-files rows, for the edited-files card's session scope
// (`agentPane.editedFiles.scope` session): the card at the latest edit covers every edit of the
// session. The pane provides them, the same array until an edit row changes, so a card's memos
// survive the snapshots of a long chat.
import { keptPrefix } from "../conversation/prefixFlatMap";
import { createContext, useSyncExternalStore } from "react";
import { isEditCard, type AcpmuxRow } from "../model";
import { RowMemo } from "../../shared/rowMemo";

export const SessionEditsContext = createContext<readonly AcpmuxRow[] | undefined>(undefined);

const editRows = new RowMemo<AcpmuxRow, boolean>();

/// A session's edit rows (`edits`, oldest first) and where each is in `rows`.
export type SessionEdits = { rows: readonly AcpmuxRow[]; at: number[]; edits: readonly AcpmuxRow[] };

/// The edit rows of `rows`. Rows before the first that differs from `previous.rows` (by object)
/// keep their result, and `edits` stays `previous.edits` when they are the same rows.
export function sessionEdits(rows: readonly AcpmuxRow[], previous?: SessionEdits): SessionEdits {
  const from = previous ? keptPrefix(previous.rows, rows) : 0;
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
/// (`foldRun`, including false while permission is pending) also keeps its tool-row renderer. The
/// layout's gap rules read the same test (model.ts `isEditCard`, transcriptGrid.ts MARK_CARD).
export const isEditRow = isEditCard;

/// The session's folder, so a tool row names a file in it by its path from there. The pane provides it.
export const SessionCwdContext = createContext<string | undefined>(undefined);

/// The session's git branch (the snapshot summary's), for the Transcript Work Log's changes card
/// (EditedFilesCard.tsx). A module store the pane sets once per change, not a context: the card is
/// deep inside the transcript's providers, and one value per page is all it needs.
let branch: string | undefined;
const branchListeners = new Set<() => void>();

export function setSessionBranch(next: string | undefined): void {
  if (next === branch) return;
  branch = next;
  for (const listener of branchListeners) listener();
}

function subscribeBranch(listener: () => void) {
  branchListeners.add(listener);
  return () => void branchListeners.delete(listener);
}

const readBranch = () => branch;

/// The session's branch; the same read serves a server render (renderToStaticMarkup in tests and
/// galleries), which throws on a store with no server snapshot.
export function useSessionBranch(): string | undefined {
  return useSyncExternalStore(subscribeBranch, readBranch, readBranch);
}
