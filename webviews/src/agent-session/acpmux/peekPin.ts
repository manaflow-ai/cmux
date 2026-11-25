// The composer status dot's card states (ComposerStatusDot.tsx): closed, peek (a hover or a keyboard
// focus shows it), pinned (a click, a tap or Enter keeps it) and held (closed by a click on the dot,
// no peek until the pointer has left the dot). The transitions are data, in
// schemas/composer-status/peek-pin.json; this only looks them up, so the table is the one place a
// rule changes and its test walks every row of it.
import table from "../../../../schemas/composer-status/peek-pin.json";

export type PeekPinState = "closed" | "peek" | "pinned" | "held";
export type PeekPinEvent =
  | "hoverIntent"
  | "hoverEnd"
  | "focusVisible"
  | "blur"
  | "clickDot"
  | "keyActivate"
  | "pressCard"
  | "pressOutside"
  | "escape"
  | "pointerLeaveDot"
  | "empty";
export type PeekPinEffect = "focusCard" | "focusDot" | "stopHover";

export type PeekPinStep = { state: PeekPinState; effects: readonly PeekPinEffect[] };

type Row = { from: string; on: string; to: string; effects: readonly string[] };

/// The table's rows by `from` and `on`, read once.
const ROWS: ReadonlyMap<string, PeekPinStep> = new Map(
  (table.transitions as readonly Row[]).map((row) => [
    `${row.from} ${row.on}`,
    { state: row.to as PeekPinState, effects: row.effects as readonly PeekPinEffect[] },
  ]),
);

const NONE: readonly PeekPinEffect[] = [];

/// The card's next state on `event` from `state`, and what to do: a pair the table has no row for
/// stays where it is and does nothing (pinned ignores hover, closed ignores a blur).
export function peekPin(state: PeekPinState, event: PeekPinEvent): PeekPinStep {
  return ROWS.get(`${state} ${event}`) ?? { state, effects: NONE };
}

/// Whether the card shows in `state`.
export function peekPinOpen(state: PeekPinState): boolean {
  return state === "peek" || state === "pinned";
}

/// The table itself, for its test.
export const PEEK_PIN_TABLE = table as {
  states: readonly PeekPinState[];
  events: readonly PeekPinEvent[];
  effects: readonly PeekPinEffect[];
  transitions: readonly { from: PeekPinState; on: PeekPinEvent; to: PeekPinState; effects: readonly PeekPinEffect[] }[];
};
