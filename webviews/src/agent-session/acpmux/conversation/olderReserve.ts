// Room above a transcript's loaded rows for the history not loaded yet.
//
// Leo (2026-10-26): "When I scroll up really far and the thing is loading, okay, the thumb just
// jitters like crazy because it's loading upwards. ... when I start from the bottom and I load my
// way up, it should just be expected that there are new elements. So you stop flickering, so you
// stop trying to recalculate the exact same thing over and over again."
//
// Without the room, every page that lands above the rows grows the content by its height and the
// view's offset by the same: the rows stay put, but the scrollbar's thumb jumps down and shrinks
// once a page. With it, the content starts as tall as the whole chat is estimated to be, and a page
// takes its height out of the room: the total, the offset and the thumb stay where they were.
//
// The room keeps one row (the pin) where it was placed: room + the pin's top among the rows is held
// constant, so rows that land or draw above the pin take the room they fill, and the pin and every
// row under it never move as pages land. Estimate once on the first nonempty layout, using the
// prompt count already available while the prompt index loads. Later counts never add room, even
// after it runs out. Row shrinkage can only give room back to the document, never refill the reserve;
// the last page removes any leftover room.

import type { AcpmuxRow } from "../model";

/// The tallest room held, under WebKit's largest scrollable height with room to spare.
export const OLDER_RESERVE_MAX = 1_000_000;

/// How much taller than the loaded rows' average the unloaded history is assumed to be. The two
/// errors cost differently: room that runs short makes every later page grow the content above the
/// reader, so the thumb drops while they scroll up, page after page; room left over goes once, when
/// the last page lands, and moves the thumb the way the reader is going. A chat's older turns are
/// often taller than its newest (tool runs, code), so the estimate leans long (chat-scroll-nightly:
/// newest turns shorter than the older ones left the room 8,000 px short, a 32 px drop of the thumb).
export const OLDER_RESERVE_HEADROOM = 1.5;

export type OlderReserve = {
  sessionId?: string;
  /// The row the room is held against, and where it was last found.
  pinId: string;
  pinIndex: number;
  rowCount: number;
  /// The room plus the pin's top among the rows: held as pages land, reduced if rows shrink.
  end: number;
  /// The room this pass held.
  room: number;
};

export type OlderReserveInput = {
  sessionId?: string;
  rows: readonly AcpmuxRow[];
  /// The rows' tops and total without any room (layout tops less ConversationLayout.origin).
  rowTop: (index: number) => number;
  rowsHeight: number;
  canLoadOlder: boolean;
  /// The chat's prompts older than the rows (the snapshot's `earlierPrompts`), when read.
  earlier?: number;
  /// The chat's prompt count while it does not hold every prompt (the snapshot's `promptCount`).
  promptCount?: number;
};

/// Where the pin is now: its last index, moved by the rows that came or went (a page prepends), or
/// a search. -1 when it left the rows.
function findPin(state: OlderReserve, rows: readonly AcpmuxRow[]): number {
  if (rows[state.pinIndex]?.id === state.pinId) return state.pinIndex;
  const shifted = state.pinIndex + rows.length - state.rowCount;
  if (rows[shifted]?.id === state.pinId) return shifted;
  return rows.findIndex((row) => row.id === state.pinId);
}

/// The first prompt among the rows (bounded: a page starts with whole turns), else the first row.
function firstPrompt(rows: readonly AcpmuxRow[]): number {
  for (let index = 0; index < Math.min(rows.length, 64); index += 1) if (rows[index]!.kind === "user") return index;
  return 0;
}

/// The height the unloaded history is estimated to take: the loaded rows' height per prompt, with
/// OLDER_RESERVE_HEADROOM, for every prompt not loaded. Undefined when the count of those is not known (no room, as before).
export function estimateOlderHeight(input: OlderReserveInput): number | undefined {
  let loaded = 0;
  for (const row of input.rows) if (row.kind === "user") loaded += 1;
  const unloaded =
    input.earlier !== undefined && input.earlier > 0
      ? input.earlier
      : input.promptCount !== undefined
        ? input.promptCount - loaded
        : 0;
  if (!(unloaded > 0) || input.rowsHeight <= 0) return undefined;
  const perPrompt = input.rowsHeight / Math.max(1, loaded);
  return Math.min(OLDER_RESERVE_MAX, Math.round(unloaded * perPrompt * OLDER_RESERVE_HEADROOM));
}

/// The room for this pass, and the state the next pass reads.
export function olderReserve(
  state: OlderReserve | undefined,
  input: OlderReserveInput,
): { reserve: number; state: OlderReserve | undefined } {
  const { rows } = input;
  const previous = state?.sessionId === input.sessionId ? state : undefined;
  // Zero is final for this session; no pin search or row scan is needed after exhaustion.
  if (previous?.room === 0) return { reserve: 0, state: previous };
  // An initial empty snapshot has nothing to estimate. Once a layout has held room, keep its
  // exhausted state through an empty snapshot so the same session cannot seed it again.
  if (rows.length === 0) return { reserve: 0, state: previous ? { ...previous, room: 0, end: 0 } : undefined };
  const found = previous ? findPin(previous, rows) : -1;
  const pin = found >= 0 ? found : firstPrompt(rows);
  const top = input.rowTop(pin);
  const reserve = !input.canLoadOlder
    ? 0
    : previous
      ? Math.min(previous.room, Math.max(0, found >= 0 ? previous.end - top : previous.room))
      : (estimateOlderHeight(input) ?? 0);
  return {
    reserve,
    state: {
      sessionId: input.sessionId,
      pinId: rows[pin]!.id,
      pinIndex: pin,
      rowCount: rows.length,
      // Rebase after shrinkage, or a pin that left: later growth consumes the room still held.
      end: reserve + top,
      room: reserve,
    },
  };
}
