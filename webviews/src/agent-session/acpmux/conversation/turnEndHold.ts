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
// The one exception is the turn's own "Worked for": it always closes at the turn's end (Lucas,
// 2026-11-11), as the Codex app's does.
import { isLineRow, MESSAGE_RUN, type AcpmuxRow } from "../model";
import { messageRunRowId } from "./messageRuns";
import { isRunning } from "./toolGroups";
import { hiddenRowFolds, WORKED } from "./turns";
import { opensTurn } from "../turnStart";
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
    const keys = hiddenRowFolds(rows, drawn, index);
    // A turn's "Worked for" always closes when the turn ends, in view or not (Lucas, 2026-11-11:
    // "the Worked for should ALWAYS collapse when the turn has ended", as Codex). A row it hides holds
    // nothing then: a message run held open under it would show open the next time Worked opens.
    if (keys.some((key) => key.startsWith(`${WORKED}-`))) continue;
    for (const key of keys) {
      const hold = key === ownRun && runKey !== undefined ? runKey : key;
      if (!folds.has(hold)) held.add(hold);
    }
  }
  return [...held];
}

/// `held` (``foldsToHold``) with one key per message run: each open run's line keeps the key it
/// toggles, and a key another row of that run brought is dropped. `drawn` is the view shaped with
/// `held` open; only its rows after the first `reused` are looked at. A running turn draws every row
/// and no message run (turns.ts `shapeLiveTurn`, cmux#38339), so at its end several rows of one run
/// the reader had in view each held the run by their own key, while the line closes by its key
/// alone: the run stayed open on the first close and needed a second click (cmux#33300).
export function oneKeyPerMessageRun(held: readonly string[], drawn: readonly AcpmuxRow[], reused = 0): string[] {
  if (held.length < 2) return [...held];
  const others = new Set<string>();
  for (let index = reused; index < drawn.length; index += 1) {
    const row = drawn[index]!;
    if (row.kind !== MESSAGE_RUN || !row.foldOpen || !row.messageRun) continue;
    for (const id of row.messageRun.rows) if (messageRunRowId(id) !== row.id) others.add(messageRunRowId(id));
  }
  return others.size === 0 ? [...held] : held.filter((key) => !others.has(key));
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

/// The "Worked for" keys the chat's last turn can have: one per prompt of the turn (its opener and
/// each steer that continues it, turns.ts `${WORKED}-<row id>`). The pane drops them from its open
/// folds when that turn ends, so the turn's Worked for is always closed at its end, whatever opened it
/// (Lucas, 2026-11-11: "the Worked for should ALWAYS collapse when the turn has ended"). Walks back
/// from the end to the turn's opener only: never the whole chat.
export function lastTurnWorkedKeys(rows: readonly AcpmuxRow[]): string[] {
  const keys: string[] = [];
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind !== "user") continue;
    keys.push(`${WORKED}-${row.id}`);
    // A steer not sent (pending, failed) also opens a turn by itself, but not this one: walk past it
    // to the prompt that opened the turn, as turns.ts `turnFoldFor` does.
    if (opensTurn(row) && !row.pending && !row.failed) break;
  }
  return keys;
}

// A running turn draws its replies and one live line, and no finished run of the stretch still
// running (turns.ts `codexRuns`, liveTurnWork.experiment.ts `line`). The runs come back when the
// stretch stops being the running one. With no fold over them that is when another prompt opens a
// new turn over it: another agent's message that arrives while the turn runs (turns.ts
// `settledWithoutSummary` draws the stretch as it came, its edits as one card at its end). Those runs
// came back between the replies a reader scrolled up had in view, in one update, and every reply
// under the first one moved down by the rows over it (30 px a run:
// agent-pane-turn-end-keeps-place.test.ts, "a turn that streams calls, a message and its end").
// While the reader is scrolled up they therefore stay out, as the reader saw the stretch, and go
// back in once the view follows the latest row again, or when the reader asks for one of them
// (Find, a link to a call).

/// How many rows before the reshaped tail are looked at for one the reader has in view. The rows in
/// view are next to each other, so a view that reaches over the tail's start has that start's last
/// rows in it; the bound keeps the look off the whole chat.
const ROWS_OVER_TAIL = 16;

/// The rows to keep out of the view after an update: the runs of `rows` that `drawn` draws though
/// the view before it (`before`) did not, when one of them comes back between rows the reader has in
/// view (`inView`). Every run that comes back in the update is held then, so the stretch reads as
/// one. The first `reused` rows of `drawn` and `before` are the same (turns.ts `reusedRows`); only
/// rows of `drawn` after that prefix are looked at.
///
/// A run comes back when, in the chat's own order (`rows`), a prompt or a row drawn before follows
/// it: its stretch ended, or went on past it. A run that nothing of those follows is new, and is not
/// held. A todo list is no such row: the view puts it under the work, whatever its place in the chat.
/// A run with a call that still runs, or that waits for the reader's permission, is never held: it
/// is news, not a row the look kept out. An edits card comes back for every edit row it merged, and
/// a run with short notes joined in for every run of it (the notes stay, as the replies they were).
/// An id in view that is no row of `drawn` (a card the view makes after the turns: received
/// messages, a shell) says nothing about where the reader is.
export function rowsToHold(
  rows: readonly AcpmuxRow[],
  drawn: readonly AcpmuxRow[],
  before: readonly AcpmuxRow[] | undefined,
  reused: number | undefined,
  inView: readonly string[],
): string[] {
  if (inView.length === 0 || !before) return [];
  const from = reused ?? 0;
  const was = new Set<string>();
  for (let index = from; index < before.length; index += 1) was.add(before[index]!.id);
  const seen = new Set(inView);
  // The finished runs the update draws that the view before it did not.
  const came = new Map<string, { over: boolean; row: AcpmuxRow }>();
  for (let index = from; index < drawn.length; index += 1) {
    const row = drawn[index]!;
    if (row.kind !== "activity" || was.has(row.id)) continue;
    if (!row.items?.some((item) => item.tool && isRunning(item.tool))) came.set(row.id, { over: false, row });
  }
  if (came.size === 0) return [];
  // The chat's own rows of the reshaped tail, back from the latest: the runs that a prompt or a row
  // drawn before follows. The live line, a date and a footer are the view's rows, not the chat's.
  const end = from > 0 ? drawn[from - 1]!.id : undefined;
  const source = new Set<string>();
  const back = new Set<string>();
  let follows = false;
  for (let index = rows.length - 1; index >= 0 && rows[index]!.id !== end; index -= 1) {
    const row = rows[index]!;
    source.add(row.id);
    if (row.kind === "activity" && follows) back.add(row.id);
    if ((row.kind === "user" && !isLineRow(row)) || (row.kind !== "plan" && was.has(row.id))) follows = true;
  }
  // Whether a row in view stands over each run: one of the last rows before the tail, or a row of
  // the chat in the tail. A date over an older page that loads is in view and is no row of the
  // chat: the page's runs come in over every row the reader reads, and move none of them.
  let over = false;
  for (let index = from - 1; index >= 0 && index >= from - ROWS_OVER_TAIL && !over; index -= 1) {
    over = seen.has(drawn[index]!.id);
  }
  for (let index = from; index < drawn.length; index += 1) {
    const { id } = drawn[index]!;
    const run = came.get(id);
    if (run) run.over = over;
    else if (seen.has(id) && source.has(id)) over = true;
  }
  const comesBack = (row: AcpmuxRow) =>
    [...(row.merged ?? []), ...(row.joined ?? []), row.id].filter((id) => back.has(id));
  // Back from the latest row drawn. A run that comes back moves a row in view when one in view is
  // under it, one over it, and a row of the chat drawn before follows it in the view.
  let followed = false;
  let under = false;
  for (let index = drawn.length - 1; index >= from; index -= 1) {
    const row = drawn[index]!;
    const run = came.get(row.id);
    if (!run) {
      if (seen.has(row.id)) under = true;
      if (row.kind !== "plan" && was.has(row.id) && source.has(row.id)) followed = true;
    } else if (followed && under && run.over && comesBack(run.row).length > 0) {
      return [...new Set([...came.values()].flatMap((each) => comesBack(each.row)))];
    }
  }
  return [];
}

const withoutRows = new WeakMap<readonly AcpmuxRow[], { held: ReadonlySet<string>; rows: readonly AcpmuxRow[] }>();

/// `rows` without the rows in `held` (``rowsToHold``): every other row is the same object, so
/// turns.ts reuses what it drew, and the same `rows` and `held` give the same list. A held row with
/// a call that runs, or that waits for the reader's permission, is drawn: it is news.
export function withoutHeldRows(rows: readonly AcpmuxRow[], held: ReadonlySet<string>): readonly AcpmuxRow[] {
  if (held.size === 0) return rows;
  const cached = withoutRows.get(rows);
  if (cached?.held === held) return cached.rows;
  let out: AcpmuxRow[] | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (!held.has(row.id) || row.items?.some((item) => item.tool && isRunning(item.tool))) {
      out?.push(row);
      continue;
    }
    out ??= rows.slice(0, index);
  }
  withoutRows.set(rows, { held, rows: out ?? rows });
  return out ?? rows;
}
