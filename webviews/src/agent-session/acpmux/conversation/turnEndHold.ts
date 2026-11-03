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
import type { AcpmuxRow } from "../model";
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
    if (!missing.delete(rows[index]!.id)) continue;
    for (const key of hiddenRowFolds(rows, drawn, index)) if (!folds.has(key)) held.add(key);
  }
  return [...held];
}

/// `folds` with `extra` open too.
export function withHeldFolds(folds: Folds, extra: ReadonlySet<string>): Folds {
  if (extra.size === 0) return folds;
  return { has: (id) => extra.has(id) || folds.has(id), size: folds.size + extra.size };
}
