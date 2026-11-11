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
// row under it never move as pages land. Estimate on the first nonempty layout, using the prompt
// count already available while the prompt index loads. Later counts never add room, even after it
// runs out. Row shrinkage can only give room back to the document, never refill the reserve; the last
// page removes any leftover room.
//
// The estimate is the loaded turns' measured height per prompt for every prompt not loaded, refined
// each time a page lands (the loaded sample grows, so the average converges on the chat's own), and
// exact where this chat was seen whole before at this width (transcriptHeights.ts: the height above
// each prompt, kept per chat). Leo (2026-11-11): "the thumb turns from a tiny thing that would imply
// a big chat to just a medium sized thumb at the top": a fixed 1.5x lean made the room half again
// the history's height, so the thumb grew by a third on the way up and the end gave the rest back.

import type { AcpmuxRow } from "../model";

/// The tallest room held, under WebKit's largest scrollable height with room to spare.
export const OLDER_RESERVE_MAX = 1_000_000;

/// How far a refined estimate must move the room before it does, in px: a page whose turns
/// average out the same leaves the room (and the thumb) where it was.
export const OLDER_RESERVE_REFINE_PX = 64;

/// The estimate leans this much over the loaded turns' average. Room taken back moves the thumb
/// up, with a reader scrolling up; room added moves it down, against them. Leaning a little high,
/// refinements shrink the room, and the last page gives back what is left over.
export const OLDER_RESERVE_LEAN = 1.02;

/// The share of each step the reader scrolls up that pays back room a refined estimate found short
/// (`payOlderRoom`). Room added at once would push the thumb down; added at under the step's own
/// height, the content grows by less than the view rose, so the thumb still moves up, only slower.
export const OLDER_RESERVE_PAY_SHARE = 0.75;

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
  /// No count of the unloaded history was known yet, so no room was ever estimated: the first
  /// count seeds it once (a chat whose first frame comes before its summary). Once seeded, or once
  /// the history is whole, counts never add room again.
  unseeded?: true;
  /// The most prompts the chat was known to hold (loaded plus unloaded), from any count read so far:
  /// a later count that names fewer (a prompt index cut at its size cap, or read for less) does not
  /// shrink the estimate.
  prompts?: number;
  /// Room a refined estimate found short, added back as the reader scrolls up (`payOlderRoom`).
  owed?: number;
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
  /// The history's height above a row, from when this chat was last held whole at this width
  /// (transcriptHeights.ts), for the pin: exact where the estimate guesses.
  knownAbove?: (row: AcpmuxRow) => number | undefined;
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

function loadedPrompts(rows: readonly AcpmuxRow[]): number {
  let loaded = 0;
  for (const row of rows) if (row.kind === "user") loaded += 1;
  return loaded;
}

/// The prompts older than the rows, as this pass's counts name them.
function unloadedPrompts(input: OlderReserveInput, loaded: number): number {
  return input.earlier !== undefined && input.earlier > 0
    ? input.earlier
    : input.promptCount !== undefined
      ? input.promptCount - loaded
      : 0;
}

/// The height the unloaded history is estimated to take: the loaded rows' height per prompt for
/// every prompt not loaded. Undefined when the count of those is not known (no room, as before).
export function estimateOlderHeight(input: OlderReserveInput, knownPrompts = 0): number | undefined {
  const loaded = loadedPrompts(input.rows);
  const unloaded = Math.max(unloadedPrompts(input, loaded), knownPrompts - loaded);
  if (!(unloaded > 0) || input.rowsHeight <= 0) return undefined;
  const perPrompt = input.rowsHeight / Math.max(1, loaded);
  return Math.min(OLDER_RESERVE_MAX, Math.round(unloaded * perPrompt * OLDER_RESERVE_LEAN));
}

/// The room for this pass, and the state the next pass reads.
export function olderReserve(
  state: OlderReserve | undefined,
  input: OlderReserveInput,
): { reserve: number; state: OlderReserve | undefined } {
  const { rows } = input;
  const previous = state?.sessionId === input.sessionId ? state : undefined;
  // Zero is final for this session (no pin search or row scan after exhaustion), unless no count
  // was ever known to seed it.
  if (previous?.room === 0 && !previous.unseeded) return { reserve: 0, state: previous };
  // An initial empty snapshot has nothing to estimate. Once a layout has held room, keep its
  // exhausted state through an empty snapshot so the same session cannot seed it again.
  if (rows.length === 0)
    return { reserve: 0, state: previous ? { ...previous, room: 0, end: 0, unseeded: undefined } : undefined };
  const found = previous ? findPin(previous, rows) : -1;
  const pin = found >= 0 ? found : firstPrompt(rows);
  const top = input.rowTop(pin);
  // The room above the first row: exact from a whole visit, else the estimate.
  const known = input.knownAbove?.(rows[pin]!);
  const loaded = loadedPrompts(rows);
  const unloaded = unloadedPrompts(input, loaded);
  const prompts = Math.max(previous?.prompts ?? 0, unloaded > 0 ? loaded + unloaded : 0) || undefined;
  const estimate = () =>
    known !== undefined
      ? Math.min(OLDER_RESERVE_MAX, Math.max(0, Math.round(known - top)))
      : estimateOlderHeight(input, prompts);
  let reserve: number;
  let unseeded: true | undefined;
  let owed = 0;
  if (!input.canLoadOlder) reserve = 0;
  else if (!previous || previous.unseeded) {
    const first = estimate();
    reserve = first ?? 0;
    unseeded = first === undefined ? true : undefined;
  } else {
    const held = Math.min(previous.room, Math.max(0, found >= 0 ? previous.end - top : previous.room));
    // A page landed (rows came above the pin): the loaded sample is larger, so the estimate is
    // better; the room takes it when it moved by more than a few lines. Between pages the room is
    // only what the pin's place leaves (a row above it drawing taller takes from it).
    const landed = found >= 0 && found !== previous.pinIndex;
    // Room over the estimate goes at once (the thumb moves up, with the reader); room under it is
    // owed, and paid as the reader scrolls up (`payOlderRoom`), never in one step.
    // A page whose turns run longer than the tail's says the history before it likely does too: the
    // room owed takes the larger of the whole sample's average and the landed rows' own.
    const refined = landed && held > 0 ? refine(estimate(), input, pin, top, prompts, known) : undefined;
    if (refined !== undefined && held - refined > OLDER_RESERVE_REFINE_PX) {
      reserve = refined;
      owed = 0;
    } else {
      reserve = held;
      owed =
        refined !== undefined
          ? refined - held > OLDER_RESERVE_REFINE_PX
            ? refined - held
            : 0
          : held > 0
            ? (previous.owed ?? 0)
            : 0;
    }
  }
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
      ...(unseeded ? { unseeded } : {}),
      ...(prompts ? { prompts } : {}),
      ...(owed > 0 ? { owed } : {}),
    },
  };
}

/// The refined estimate after a page landed: the loaded rows' average (`overall`), or, when larger,
/// the average of the rows above the pin (those the pages since the open brought) for every prompt
/// still unloaded. Exact (`known`) wins.
function refine(
  overall: number | undefined,
  input: OlderReserveInput,
  pin: number,
  top: number,
  prompts: number | undefined,
  known: number | undefined,
): number | undefined {
  if (known !== undefined || overall === undefined) return overall;
  let above = 0;
  for (let index = 0; index < pin; index += 1) if (input.rows[index]!.kind === "user") above += 1;
  if (above === 0 || !(top > 0)) return overall;
  const loaded = loadedPrompts(input.rows);
  const unloaded = Math.max(unloadedPrompts(input, loaded), (prompts ?? 0) - loaded);
  if (!(unloaded > 0)) return overall;
  const recent = Math.min(OLDER_RESERVE_MAX, Math.round((top / above) * unloaded * OLDER_RESERVE_LEAN));
  return Math.max(overall, recent);
}

/// Pays room owed (`OlderReserve.owed`) for a scroll up of `rose` px: at most OLDER_RESERVE_PAY_SHARE
/// of it, so the view's content grows by less than the view rose and the thumb keeps moving up.
/// The same state when nothing is owed or the reader did not rise.
export function payOlderRoom(state: OlderReserve | undefined, rose: number): OlderReserve | undefined {
  if (!state?.owed || !(rose > 0) || state.room <= 0) return state;
  const pay = Math.min(state.owed, rose * OLDER_RESERVE_PAY_SHARE, OLDER_RESERVE_MAX - state.room);
  if (!(pay > 0.5)) return state;
  const owed = state.owed - pay;
  const { owed: _paid, ...rest } = state;
  return { ...rest, room: state.room + pay, end: state.end + pay, ...(owed > 0.5 ? { owed } : {}) };
}
