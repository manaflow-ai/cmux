// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); other agents fork only at a chat's end, so none of their prompts edit. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
import type { AcpmuxRow } from "../model";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | undefined): Map<string, number> {
  const seqs = new Map<string, number>();
  if (family !== "claude") return seqs;
  let through: number | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary" && row.seq !== undefined) through = row.seq;
    else if (row.kind === "user" && through !== undefined && row.text && !row.failed && !row.queued && !row.pending)
      seqs.set(row.id, through);
  }
  return seqs;
}

/// The same prompts as a string, so the App rebuilds its actions only when they change (not on every
/// streamed row).
export const editableKey = (seqs: ReadonlyMap<string, number>) =>
  [...seqs].map(([id, seq]) => `${id}:${seq}`).join(",");

/// The prompts back from `editableKey`.
export function editableSeqs(key: string): Map<string, number> {
  const seqs = new Map<string, number>();
  for (const entry of key ? key.split(",") : []) {
    const at = entry.lastIndexOf(":");
    seqs.set(entry.slice(0, at), Number(entry.slice(at + 1)));
  }
  return seqs;
}

// ↑ on an empty composer edits the chat's last prompt in place, as in Claude's apps (Leo, 2026-10-20;
// Debug Settings' "↑ edits the last prompt", composerSettings.ts `upEditsLastPrompt`). Each drawn
// prompt that edits registers how to open its editor; a prompt the transcript has not drawn has none.
/// Opens a prompt's editor; `back` gives the keyboard back to whoever opened it when the edit is cancelled.
type PromptEditorOpener = (back?: () => void) => void;
const editors = new Map<string, PromptEditorOpener>();

/// Registers how the prompt `rowId` opens its editor, until the returned function runs.
export function registerPromptEditor(rowId: string, open: PromptEditorOpener): () => void {
  editors.set(rowId, open);
  return () => {
    if (editors.get(rowId) === open) editors.delete(rowId);
  };
}

/// The chat's last prompt, when it edits: an older prompt never opens in its place.
export function lastEditablePrompt(rows: readonly AcpmuxRow[], seqs: ReadonlyMap<string, number>): string | undefined {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind === "user" && row.text && !row.queued && !row.pending) return seqs.has(row.id) ? row.id : undefined;
  }
  return undefined;
}

/// Opens the editor of the prompt `rowId`; false when it has none drawn.
export function openPromptEditor(rowId: string | undefined, back?: () => void): boolean {
  const open = rowId === undefined ? undefined : editors.get(rowId);
  open?.(back);
  return open !== undefined;
}
