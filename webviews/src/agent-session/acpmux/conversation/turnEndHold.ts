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

// A command still running in an earlier run is the live line's, and that run draws no row for it
// (turns.ts `lineCall`, `codexRuns`; Leo, 2026-10-22, wanted it off its row and on the line). When
// the line lets go of it (it finishes, a newer call takes the line, the turn ends), it went back
// into its run as a row, and every row under it moved down one row, under a reader scrolled up
// with that run in view (cmux#33200; Leo, 2026-11-03: "im still getting these weird layout shift
// things when im already scrolled up due to idk tool calls shifting/messages coming in maybe that
// should not happen"). While the reader is scrolled up it therefore stays out of its run, as the
// line had it, and goes back in once they are at the latest row again, where the view follows.

/// The call the live line names out of an earlier run in `drawn` (the row's `linedCall`), if any.
/// The live line is the last row of the running turn, so the walk back is short.
export function linedCallOf(drawn: readonly AcpmuxRow[]): string | undefined {
  for (let index = drawn.length - 1; index >= 0 && index >= drawn.length - 4; index -= 1) {
    const call = drawn[index]!.linedCall;
    if (call !== undefined) return call;
  }
  return undefined;
}

/// The calls to keep out of their runs after an update, given the call the line named out of its
/// run before it (`before`) and the one it names now (`now`): the one it let go of.
export function callsToHold(before: string | undefined, now: string | undefined, held: ReadonlySet<string>) {
  return before !== undefined && before !== now && !held.has(before) ? before : undefined;
}

const withoutCache = new WeakMap<AcpmuxRow, { held: ReadonlySet<string>; row: AcpmuxRow | null }>();

/// `rows` without the tool calls in `held`: a row that holds one is copied without it (a row left
/// with nothing is dropped), every other row is the same object, so turns.ts reuses what it drew.
/// A copy's version is off every version the row itself has, so it draws again when the call comes back.
export function withoutHeldCalls(rows: readonly AcpmuxRow[], held: ReadonlySet<string>): readonly AcpmuxRow[] {
  if (held.size === 0) return rows;
  let out: AcpmuxRow[] | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    let next: AcpmuxRow | null = row;
    if (row.kind === "activity" && row.items?.some((item) => item.tool && held.has(item.tool.id))) {
      const cached = withoutCache.get(row);
      if (cached?.held === held) next = cached.row;
      else {
        const items = row.items.filter((item) => !(item.tool && held.has(item.tool.id)));
        next = items.length ? { ...row, items, version: row.version + 0.5 } : null;
        withoutCache.set(row, { held, row: next });
      }
    }
    if (next === row && !out) continue;
    out ??= rows.slice(0, index);
    if (next) out.push(next);
  }
  return out ?? rows;
}
