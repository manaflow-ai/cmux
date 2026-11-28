// Which of the running turn's rows the transcript draws, for the bypasses that keep the pane's
// snapshot when a record changes only a row nobody sees (liveThought.ts `thoughtOnly`), and for
// the pane's per-kind counts (`changeHidden`). A hidden call is still read by the live line
// (turns.ts `lineCall`, `liveClock`: "Reading x", then "Thinking" from its end), which hears it
// without the pane (liveCallLine.ts). Under the running turn's closed "Working for" (turns.ts
// `shapeLiveTurn`, liveTurnWork `folded` with the fold shut) the transcript draws none of the
// turn's activity rows but the few that keep their own row (a call waiting on its permission).
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { WORKED } from "./conversation/turns";
import { oneRowChangeFrom } from "./rowChanges";

/// The ids of the running turn's rows the transcript drew while that turn's work sat under its
/// closed "Working for", else undefined. A row of the turn missing here draws nothing; only the
/// live line hears it (liveThought.ts `liveThoughtHeard`, the header's clock).
let shownUnderFold: Set<string> | undefined;
/// Whether that closed "Working for" was drawn with nothing to open yet (turns.ts `foldEmpty`): its
/// chevron unseen until a step lands under it.
let foldDrawnEmpty = false;

/// What the transcript drew of the running turn, read from the end back to the turn's prompt, so
/// O(the running turn's rows), not the chat's. VirtualTranscript calls it (through
/// liveThought.ts `drewThoughts`) with the rows it draws.
export function drewRunningTurn(rows: readonly AcpmuxRow[] | undefined): void {
  const shown = new Set<string>();
  let folded = false;
  let empty = false;
  if (rows)
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]!;
      if (row.kind === "user") break;
      shown.add(row.id);
      if (row.kind === WORKED && row.turnPhase === "running" && row.foldOpen === false) {
        folded = true;
        empty = row.foldEmpty === true;
      }
    }
  shownUnderFold = folded ? shown : undefined;
  foldDrawnEmpty = folded && empty;
}

/// Whether the transcript last drew the running turn's closed "Working for" with nothing under it:
/// a hidden row that comes to show (a thought no longer quiet) must draw the pane, so the header
/// shows its chevron (liveThought.ts `thoughtOnly`).
export const drewEmptyFold = (): boolean => foldDrawnEmpty;

/// Whether the transcript last drew the running turn's work under its closed "Working for".
export const drewUnderClosedFold = (): boolean => shownUnderFold !== undefined;

/// Whether `rows[index]` is one of the running turn's rows that its closed "Working for" hides
/// (`shownUnderFold`): no prompt after it, so it is that turn's, and the transcript drew no row of
/// its id. In a long chat nearly every thought chunk and tool call lands there (the default arm,
/// fold shut), and each one drew the whole pane for a row nobody sees. Opening the fold draws the
/// rows from the pane's newest snapshot (each bypass's store hands it over).
export function hiddenUnderFold(rows: readonly AcpmuxRow[], index: number): boolean {
  const row = rows[index];
  if (!shownUnderFold || !row || shownUnderFold.has(row.id)) return false;
  for (let at = rows.length - 1; at > index; at -= 1) if (rows[at]!.kind === "user") return false;
  return true;
}

/// Whether the one row `next` changed from `previous` (rowChanges.ts) is hidden under the running
/// turn's closed fold (`hiddenUnderFold`). The pane counts these (perf.ts `record:row-hidden`, and
/// `pane:row-hidden` when one still redraws the pane) for the replay bench's per-kind table.
export function changeHidden(previous: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  const index = oneRowChangeFrom(next.rows, previous.rows);
  return index !== undefined && hiddenUnderFold(next.rows, index);
}
