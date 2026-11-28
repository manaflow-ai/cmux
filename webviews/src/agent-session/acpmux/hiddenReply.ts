// A background turn's reply streaming while its line hides it (conversation/backgroundTurns.ts
// `hiddenInBackground`: a running turn's reply waits behind its line until acpmux says whether it
// is quiet). Each chunk drew the whole pane (its root, header, transcript, composer) for a row
// nobody sees: the replay bench's top redraw class (`row@agent_message_chunk`, the reply drawn
// `none@absent,bg=y`, 101 of ~800 whole-pane draws a run).
//
// When a snapshot differs from the one the pane drew only in such a reply's text growing
// (streamingRow.ts `textOnlyRow`, the same test the drawn reply's fast path takes) and the
// transcript's last draw did not hold that row (`drewHiddenRows`), the pane keeps its snapshot.
// Hiding the row never reads its text (the line's fold, the turn's running or quiet state, the
// prompt after it), so the next chunk keeps it hidden; a reply whose text was empty is not taken,
// as its first words are what make it draw (visibleMessage.ts `isVisiblyEmptyMessage`).
//
// Anything that draws the row later (its line opened, Find, a page moved) draws it from the pane's
// older snapshot: the transcript tells `drewHiddenRows` from its layout effect, which asks the pane
// to draw the newest snapshot at once (`flush`), before that pass paints. A pane draw whose rows
// carry the text the pane went around clears the entry (`redraw`).
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { sameButRows } from "./liveToolOutput";
import { streamingRowBlocked, textOnlyRow } from "./streamingRow";
import { isVisiblyEmptyMessage } from "./conversation/visibleMessage";

/// The rows the pane went around, by id: where the newest snapshot held each and its text there.
const ahead = new Map<string, { readonly index: number; readonly text: string }>();
/// The ids of the rows the transcript last drew, from its prompt-free end (`drewHiddenRows`).
let drawnTail: ReadonlySet<string> | undefined;
let flush: (() => void) | undefined;

export const hiddenReply = {
  /// The pane kept its snapshot for `next.rows[index]`.
  set(next: AcpmuxSnapshot, index: number): void {
    const row = next.rows[index]!;
    ahead.set(row.id, { index, text: row.text ?? "" });
  },
  /// The pane draws `next`: an entry whose row there carries the text the pane went around is done.
  redraw(next: AcpmuxSnapshot): void {
    if (ahead.size === 0) return;
    for (const [id, entry] of ahead) {
      const row = next.rows[entry.index];
      if (row?.id === id ? row.text === entry.text : !next.rows.some((other) => other.id === id)) ahead.delete(id);
    }
  },
  /// What draws the client's newest snapshot at once; returns the unregister.
  onFlush(draw: () => void): () => void {
    flush = draw;
    return () => {
      if (flush === draw) flush = undefined;
    };
  },
  /// Rows the pane went around and has not drawn since (tests).
  pending: (): number => ahead.size,
  /// Forgets everything (tests).
  reset(): void {
    ahead.clear();
    drawnTail = undefined;
    flush = undefined;
  },
};

/// What the transcript drew (VirtualTranscript's layout effect, with the rows it draws): the ids of
/// its rows after its last prompt, O(the running turn's rows); and, while the pane went around a
/// row, whether this pass drew it from the pane's older rows, so the pane draws the newest at once.
export function drewHiddenRows(rows: readonly AcpmuxRow[] | undefined): void {
  const tail = new Set<string>();
  if (rows)
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]!;
      if (row.kind === "user") break;
      tail.add(row.id);
    }
  drawnTail = rows ? tail : undefined;
  if (ahead.size === 0 || !rows) return;
  if (!rows.some((row) => ahead.has(row.id))) return;
  ahead.clear();
  flush?.();
}

/// The index of the one row `next` changes from `drawn` (the snapshot the pane drew) when it is only
/// a background turn's streaming reply growing, that reply already had words, it is the running
/// turn's (no prompt after it), and the transcript's last draw of that turn did not hold it; else -1.
export function hiddenReplyOnly(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): number {
  if (!drawnTail || streamingRowBlocked() || !sameButRows(drawn, next)) return -1;
  const at = textOnlyRow(drawn.rows, next.rows);
  if (at < 0) return -1;
  const before = drawn.rows[at]!;
  if (before.inBackground === undefined || isVisiblyEmptyMessage(before) || drawnTail.has(before.id)) return -1;
  for (let index = next.rows.length - 1; index > at; index -= 1) if (next.rows[index]!.kind === "user") return -1;
  return at;
}
