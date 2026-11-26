import { type AcpmuxRow, isLineRow } from "../model";
import { LIVE_THINKING } from "../conversation/turns";

/// Whether the rows at the tail changed by more than the reply's own text: a row came or went, or a
/// row other than a reply and the live line changed (a call finished, a thought grew, a steer
/// landed). O(1): the last ARRIVAL_TAIL rows, by id and version.
export const ARRIVAL_TAIL = 6;
/// Sent thinking markers live only for the recent sends that can still be in their landing window.
/// This keeps the identity side table constant-size even when a long transcript is retained.
export const SENT_PROMPT_ID_LIMIT = 32;

export function rememberSentPromptId(ids: Set<string>, id: string): void {
  ids.delete(id);
  ids.add(id);
  while (ids.size > SENT_PROMPT_ID_LIMIT) {
    const oldest = ids.values().next().value as string | undefined;
    if (oldest === undefined) break;
    ids.delete(oldest);
  }
}
/// How long after a row arrived its room still counts as the arrival: the passes that measure it.
export const ARRIVAL_PASS_MS = 100;
export function arrivedAtTail(before: readonly AcpmuxRow[], after: readonly AcpmuxRow[]): boolean {
  if (before.length !== after.length) return true;
  for (let index = after.length - 1; index >= Math.max(0, after.length - ARRIVAL_TAIL); index -= 1) {
    const row = after[index]!;
    const was = before[index]!;
    if (row.id !== was.id) return true;
    if (row === was || row.version === was.version) continue;
    if (row.id !== LIVE_THINKING && row.kind !== "assistant") return true;
  }
  return false;
}

/// Whether each rows list a render drew holds only a streamed token over the list the render before it
/// drew (`arrivedAtTail`): TranscriptView `tokenRows`. Kept per list, answered once when a render
/// first draws it, so a render React discards leaves no other list's answer behind. It keeps the list
/// drawn before itself, so the render reads no ref for it.
export class TokenRows {
  private readonly answers = new WeakMap<readonly AcpmuxRow[], boolean>();
  private before: readonly AcpmuxRow[];
  constructor(rows: readonly AcpmuxRow[]) {
    this.before = rows;
  }
  /// Takes a render's rows.
  draw(rows: readonly AcpmuxRow[]): void {
    const before = this.before;
    this.before = rows;
    if (!this.answers.has(rows))
      this.answers.set(rows, before !== rows && before[0]?.id === rows[0]?.id && !arrivedAtTail(before, rows));
  }
  get(rows: readonly AcpmuxRow[]): boolean | undefined {
    return this.answers.get(rows);
  }
}

/// The newest prompt's row index (a user row that is no line), or -1: the turn the room the reader
/// came back to is kept for (`heldRoom.reader`). Reads back from the end to that prompt only.
export function newestPromptIndex(rows: readonly AcpmuxRow[]): number {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind === "user" && !isLineRow(row)) return index;
  }
  return -1;
}

/// The rows that came at the tail bring none of the reply's text: a send's or a steer's own rows (the
/// prompt, its date, the live line). The steady arm moves those at once and lets the reply drift.
/// O(rows that came).
export function noReplyCame(before: readonly AcpmuxRow[], after: readonly AcpmuxRow[]): boolean {
  const first = Math.max(0, before.length - ARRIVAL_TAIL);
  const known = new Set<string>();
  for (let index = first; index < before.length; index += 1) known.add(before[index]!.id);
  for (let index = first; index < after.length; index += 1) {
    const row = after[index]!;
    if (!known.has(row.id) && row.kind === "assistant") return false;
  }
  return true;
}

/// Whether a pass brought a sent prompt (a new user row that is no line). It lands at once with what
/// came in the same pass (its live line, a reply already there); tool rows and the reply that land in
/// the send's window after it are the turn's and chase. O(1): inspect bounded windows at the append
/// boundary and tail, so a prompt followed by a burst of rows is still recognized without scanning history.
export function broughtSentPrompt(before: readonly AcpmuxRow[], after: readonly AcpmuxRow[]): boolean {
  const promptRow = (row: AcpmuxRow | undefined): row is AcpmuxRow => row?.kind === "user" && !isLineRow(row);
  const becameCanonical = (was: AcpmuxRow | undefined, row: AcpmuxRow | undefined) => {
    if (!promptRow(was) || !promptRow(row)) return false;
    // The normal path keeps the optimistic `local-*` row, but a rebuild can replace it in place.
    // Treat that identity hand-off as the send landing even when the snapshot length is unchanged.
    const optimistic =
      was.id.startsWith("local-") ||
      was.pending === true ||
      was.delivery?.state === "sending" ||
      was.delivery?.state === "delivered";
    const settled = row.pending !== true && row.delivery?.state !== "sending" && row.delivery?.state !== "delivered";
    return optimistic && settled && (was.id !== row.id || was.version !== row.version);
  };
  if (after.length === before.length) {
    const first = Math.max(0, before.length - ARRIVAL_TAIL);
    for (let index = first; index < after.length; index += 1)
      if (becameCanonical(before[index], after[index])) return true;
    return false;
  }
  if (after.length < before.length) return false;
  const seen = new Set<number>();
  const first = Math.max(0, before.length - ARRIVAL_TAIL);
  const last = Math.min(after.length, before.length + ARRIVAL_TAIL);
  for (let index = first; index < last; index += 1) seen.add(index);
  for (let index = Math.max(0, after.length - ARRIVAL_TAIL); index < after.length; index += 1) seen.add(index);
  for (const index of seen) {
    const row = after[index]!;
    const was = before[index];
    if (row.kind === "user" && !isLineRow(row) && row.id !== was?.id) return true;
  }
  return false;
}
