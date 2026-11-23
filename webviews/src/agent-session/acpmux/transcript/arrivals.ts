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

/// `kept.end`: where the kept room ends, measured from the top of the prompt it is kept under (`tail`
/// below): the rows that come under the prompt fill the room instead of pushing it down.
export type ReaderRoom = {
  followed: boolean;
  left?: true;
  kept?: { room: number; prompt: string | undefined; end: number };
};

/// The room under the last row this pass, and what of it is kept for the reader (`heldRoom.reader`): followed,
/// the stack's room (`followedRoom`), or more where the reader came back down to room held while they were
/// scrolled up; scrolled up, the room held (`held`).
/// The kept room is space the rows already had, so the turn's rows fill it as they come: its end stays where
/// it was drawn (`end`, from the prompt's top) and each row that arrives takes its height out of it, so
/// nothing the reader sees moves, and once the rows reach the stack's room it is gone. Kept as a fixed
/// height, it stayed under the live line for the rest of the turn while every row arrived above it (Leo,
/// 2026-11-22: "for some reason there's also a ton of space at the bottom? idk if it was accounting maybe
/// for tool calls in a long steered with attachment situation").
/// `tail`: the rows' height from the newest prompt's top (the whole content without one) to the rows' end.
export function roomUnderRows(
  { room: held, reader }: { room: number; reader: ReaderRoom },
  pass: {
    following: boolean;
    sessionSwitched: boolean;
    followedRoom: number;
    prompt: string | undefined;
    /// Read only while room is held or kept.
    tail: () => number;
  },
): { room: number; kept: ReaderRoom["kept"] } {
  if (pass.sessionSwitched) return { room: pass.followedRoom, kept: undefined };
  if (!pass.following) return { room: held, kept: undefined };
  const fresh = !reader.followed && reader.left === true && held > pass.followedRoom + 0.5;
  const carried = reader.followed && reader.kept !== undefined && reader.kept.prompt === pass.prompt;
  if (!fresh && !carried) return { room: pass.followedRoom, kept: undefined };
  const tail = pass.tail();
  const end = fresh ? tail + held : reader.kept!.end;
  const left = Number.isFinite(end - tail) ? end - tail : 0;
  // Filled down to the stack's room: nothing is kept any longer.
  if (left <= pass.followedRoom + 0.5)
    // No room kept: the stack's room as it is, below zero too (what an opened tray lies over, `trayHold`).
    return { room: pass.followedRoom, kept: undefined };
  return { room: left, kept: { room: left, prompt: pass.prompt, end } };
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
