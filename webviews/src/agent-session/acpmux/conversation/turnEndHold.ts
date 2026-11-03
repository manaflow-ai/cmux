// A turn that ends while the reader is scrolled up keeps what they see where it is (Leo,
// 2026-11-03: "sometimes when an agent completes a message while im scrolled up the entire chat
// kinda hitches/shifts a bit? or the tool calls collpase then expand some messages? idk but it
// shouldnt realy move i think").
//
// At a turn's end its work folds (Codex under one "Worked for", Claude per run of calls). Over rows
// in the reader's view that fold pulled them out from under the reader: the first visible row was
// gone, the view anchored on a row further down, and the chat jumped. Rows the reader has in view
// therefore keep their open state while the reader is scrolled up: each fold an update would close
// over one of them stays open, as if the reader had opened it, and closes only when they close it.
import { isLineRow, MESSAGE_RUN, type AcpmuxRow } from "../model";
import { messageRunRowId } from "./messageRuns";
import { hiddenRowFolds } from "./turns";
import type { Folds } from "./viewFolds";

/// The folds to open so every row in `inView` that `rows` holds stays drawn in `drawn`, the view
/// after an update; `before` is the view before it, and the first `reused` rows of the two are the
/// same (turns.ts `reusedRows`). Only rows after that prefix can have gone, so the work is bounded
/// by what the update reshaped (the running turn), never the whole chat. Rows the view adds (the
/// live line, a date) are not in `rows` and need no fold.
export function foldsToHold(
  rows: readonly AcpmuxRow[],
  drawn: readonly AcpmuxRow[],
  before: readonly AcpmuxRow[] | undefined,
  reused: number | undefined,
  inView: readonly string[],
  folds: Folds,
): string[] {
  if (inView.length === 0 || !before) return [];
  const from = reused ?? 0;
  const was = new Set<string>();
  for (let index = from; index < before.length; index += 1) was.add(before[index]!.id);
  const now = new Set<string>();
  for (let index = from; index < drawn.length; index += 1) now.add(drawn[index]!.id);
  const missing = new Set(inView.filter((id) => was.has(id) && !now.has(id)));
  if (missing.size === 0) return [];
  const held = new Set<string>();
  // The rows that went are the reshaped tail's, near the end: walk back from it.
  for (let index = rows.length - 1; index >= 0 && missing.size > 0; index -= 1) {
    const row = rows[index]!;
    if (!missing.delete(row.id)) continue;
    // A row in a message run that was open keeps that run open by the key its line toggles, never
    // by a key of its own: the line closes by its key alone, so a second key kept the run open on
    // the first click (cmux#33300).
    const ownRun = messageRunRowId(row.id);
    const runKey = openRunKeyOf(before, row.id);
    for (const key of hiddenRowFolds(rows, drawn, index)) {
      const hold = key === ownRun && runKey !== undefined ? runKey : key;
      if (!folds.has(hold)) held.add(hold);
    }
  }
  return [...held];
}

/// The key of the open message-run line in `drawn` whose rows hold `rowId` (messageRuns.ts): the
/// id of the line its rows follow. The walk goes back from the row to the line before it, and stops
/// at the turn's prompt, which a run never crosses.
function openRunKeyOf(drawn: readonly AcpmuxRow[], rowId: string): string | undefined {
  let index = drawn.length - 1;
  while (index >= 0 && drawn[index]!.id !== rowId) index -= 1;
  for (index -= 1; index >= 0; index -= 1) {
    const row = drawn[index]!;
    if (row.kind === MESSAGE_RUN) return row.foldOpen && row.messageRun?.rows.includes(rowId) ? row.id : undefined;
    if (row.kind === "user" && !isLineRow(row)) return undefined;
  }
  return undefined;
}

/// `folds` with `extra` open too.
export function withHeldFolds(folds: Folds, extra: ReadonlySet<string>): Folds {
  if (extra.size === 0) return folds;
  return { has: (id) => extra.has(id) || folds.has(id), size: folds.size + extra.size };
}
