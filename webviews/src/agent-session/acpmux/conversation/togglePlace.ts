import type { AcpmuxRow } from "../model";

/// What Toggle Terminal and Chat reads of the chat before a swap (cmux-window-rules `tabs::place`):
/// the person's prompts, oldest first, and `at`, the prompt whose turn the reader has in view
/// (null while the view follows the latest message). The terminal shows the same prompts, so a
/// swap lands at the same turn in the other view, both ways (Leo, 2026-11-12: two live views of
/// one session).
export type TogglePlace = { prompts: string[]; at: number | null };

const isPrompt = (row: AcpmuxRow) => row.kind === "user" && (row.text?.trim() ?? "") !== "";

/// The fold's copy of a row wears the row's id with `:fold` after it (turns.ts).
const baseId = (id: string) => (id.endsWith(":fold") ? id.slice(0, -":fold".length) : id);

/// The chat's prompts and the one at or above `anchor` (the transcript's resting place, null or
/// undefined at the latest message). A place above the first prompt counts as the first turn; one
/// the rows lack (not loaded) as the latest message.
export function togglePlace(rows: readonly AcpmuxRow[], anchor: { rowId: string } | null | undefined): TogglePlace {
  const prompts: string[] = [];
  const anchorId = anchor ? baseId(anchor.rowId) : undefined;
  let at: number | null = null;
  let anchored = false;
  for (const row of rows) {
    if (isPrompt(row)) prompts.push(row.text!);
    if (!anchored && row.id === anchorId) {
      anchored = true;
      at = Math.max(0, prompts.length - 1);
    }
  }
  return { prompts, at: prompts.length === 0 ? null : at };
}

/// The id of prompt `index`'s row (the order `togglePlace` names them), undefined past the end.
export function togglePromptRow(rows: readonly AcpmuxRow[], index: number): string | undefined {
  let seen = 0;
  for (const row of rows) {
    if (!isPrompt(row)) continue;
    if (seen === index) return row.id;
    seen += 1;
  }
  return undefined;
}
