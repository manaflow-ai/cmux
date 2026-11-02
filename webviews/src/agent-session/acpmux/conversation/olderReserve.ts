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
// row under it never move. Only a wrong estimate shows: the room runs out with history still to
// load (a new estimate, one step of the thumb), or the last page leaves room over (it goes, one step).

import type { AcpmuxRow } from "../model";

/// The tallest room held, under WebKit's largest scrollable height with room to spare.
export const OLDER_RESERVE_MAX = 1_000_000;

export type OlderReserve = {
  sessionId?: string;
  /// The row the room is held against, and where it was last found.
  pinId: string;
  pinIndex: number;
  /// The pin's index when the room was estimated: still there, no page has landed since.
  pinFirst: number;
  rowCount: number;
  /// The room plus the pin's top among the rows: constant while the pin is held.
  end: number;
  /// The room this pass held.
  room: number;
  /// The counts the estimate read (`earlier`, `promptCount`): a count that arrives later estimates again.
  counts: string;
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

const countsOf = (input: OlderReserveInput) => `${input.earlier ?? ""}:${input.promptCount ?? ""}`;

/// The first prompt among the rows (bounded: a page starts with whole turns), else the first row.
function firstPrompt(rows: readonly AcpmuxRow[]): number {
  for (let index = 0; index < Math.min(rows.length, 64); index += 1) if (rows[index]!.kind === "user") return index;
  return 0;
}

/// The height the unloaded history is estimated to take: the loaded rows' height per prompt, for
/// every prompt not loaded. Undefined when the count of those is not known (no room, as before).
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
  return Math.min(OLDER_RESERVE_MAX, Math.round(unloaded * perPrompt));
}

/// The room for this pass, and the state the next pass reads.
export function olderReserve(
  state: OlderReserve | undefined,
  input: OlderReserveInput,
): { reserve: number; state: OlderReserve | undefined } {
  const { rows } = input;
  if (!input.canLoadOlder || rows.length === 0) return { reserve: 0, state: undefined };
  if (state && state.sessionId === input.sessionId) {
    const pin = findPin(state, rows);
    if (pin >= 0) {
      const reserve = Math.max(0, state.end - input.rowTop(pin));
      // Still room, or the estimate already ran out for these rows and counts: no new count until a
      // page lands or a count arrives.
      if (reserve > 0 || (pin === state.pinFirst && state.room === 0 && state.counts === countsOf(input)))
        return { reserve, state: { ...state, pinIndex: pin, rowCount: rows.length, room: reserve } };
    }
  }
  // A new chat, a pin that left, or room that ran out with history still to load: estimate again,
  // held against the first prompt. Not a row above it: a date divider there is replaced when the
  // turn before it lands, and a pin that leaves would estimate again on every page.
  const estimate = estimateOlderHeight(input) ?? 0;
  const pin = firstPrompt(rows);
  return {
    reserve: estimate,
    state: {
      sessionId: input.sessionId,
      pinId: rows[pin]!.id,
      pinIndex: pin,
      pinFirst: pin,
      counts: countsOf(input),
      rowCount: rows.length,
      end: estimate + input.rowTop(pin),
      room: estimate,
    },
  };
}
