// How much of the one-line hat's deck of marks the bar's width holds (Leo, 2026-11-27, on "14
// subagents working" followed by eight icons and "+12 more": "hm should we compact these and drop
// them away in favour of text when things shrink?" / "this is just an awkward looking layout"; and
// on the "+12 more" a panel icon was drawn over: "overlapping text here what do we doooo").
//
// The bar swaps whole forms, never letters, the way the composer's row does (composerRowFit.ts
// COMPOSER_FIT_STEPS): richest first, each level a form of the deck, the sentence always whole.
//   0  up to DECK_MARKS marks, side by side, "+N more"
//   1  up to 5 marks overlapped into a stack, "+N"
//   2  up to 3 marks overlapped, "+N"
//   3  no marks: the sentence alone (the open list's lines are the way to each one)
// A bar width (px, at or under) gives each level its start; DECK_FIT_STEPS is the table, one place to
// retune. HatHeadDeck.tsx then measures: while the bar's words would truncate or its trailing
// controls would be pushed out, it takes the next level too, so a long sentence in another language
// never lets the deck run over the panel button.

export type DeckLevel = 0 | 1 | 2 | 3;

/** The bar widths (px, at or under) where the deck gives up a form. */
export const DECK_FIT_STEPS = {
  /** The marks overlap and the count drops "more". */
  stacked: 560,
  /** Three marks at most. */
  few: 440,
  /** No marks: the words alone. */
  wordsOnly: 340,
} as const;

/** The marks each level draws at most (level 0 takes the caller's cap). */
export const DECK_LEVEL_MARKS: readonly [number, number, number, number] = [Infinity, 5, 3, 0];

/** The level a bar of `width` px starts at; an unmeasured bar (0 or less) takes the richest. */
export function deckLevelAt(width: number): DeckLevel {
  if (width <= 0) return 0;
  if (width <= DECK_FIT_STEPS.wordsOnly) return 3;
  if (width <= DECK_FIT_STEPS.few) return 2;
  if (width <= DECK_FIT_STEPS.stacked) return 1;
  return 0;
}

/** How many marks `level` draws of `count` lines, under `cap` (the most marks the deck ever draws). */
export function deckMarksAt(level: DeckLevel, count: number, cap: number): number {
  return Math.min(count, cap, DECK_LEVEL_MARKS[level]);
}
