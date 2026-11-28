// The list's FLIP of the rows under a disclosure (docs/design/transcript-motion-model.md, rule 7 and
// step 5): a toggle's body takes its height in one frame (fold.ts), the list places the rows under it
// at their new tops, and each of those rows plays from where it was drawn to its new place, on one
// clock that ends `ms` after the toggle. Only `translate` moves (a layout property never animates),
// only the list moves a row, and a row's own content never translates itself or a sibling.
//
// Offsets are read against the anchor row (the toggle's own row), so a scroll write that keeps the
// anchor on its pixel (the fold hold, foldAnchor.ts) is no move of the rows under it: only the
// anchor's change of height is.
//
// A placement during the motion (the row measured again, a stream's growth) plays the row from where
// it is drawn now to its newer place, inside what is left of the same clock: never a second clock,
// never a jump. The flip ends in the list's settle: no animation left on any row.
//
// Stop condition: the clock ends `ms` after `captureRowFlip`; `playRowFlip` past that ends it.

export type RowFlip = {
  anchor: HTMLElement;
  /// Per moving row: its place against the anchor that its current motion ends at.
  rows: Map<HTMLElement, { target: number; move?: Animation }>;
  until: number;
  easing: string;
};

/// The visual offset of `row` from `anchor` (with any motion playing on it).
const drawnOffset = (row: HTMLElement, anchor: HTMLElement) =>
  row.getBoundingClientRect().top - anchor.getBoundingClientRect().top;

/// The placed offset of `row` from `anchor` (layout only: no transform or translate counts).
const placedOffset = (row: HTMLElement, anchor: HTMLElement) => row.offsetTop - anchor.offsetTop;

/**
 * Reads where the rows under `anchor` are drawn before a disclosure changes it. `rows` are the
 * mounted rows that may move (the anchor's followers in list order). Returns undefined when there is
 * nothing to move or no time to move it in.
 */
export function captureRowFlip(
  anchor: HTMLElement,
  rows: Iterable<HTMLElement>,
  options: { now: number; ms: number; easing: string },
): RowFlip | undefined {
  if (!(options.ms > 0) || typeof anchor.animate !== "function") return undefined;
  const flip: RowFlip = { anchor, rows: new Map(), until: options.now + options.ms, easing: options.easing };
  for (const row of rows) if (row !== anchor) flip.rows.set(row, { target: placedOffset(row, anchor) });
  return flip.rows.size ? flip : undefined;
}

/**
 * After a placement: each row whose place moved plays from where it is drawn to its new place, in
 * what is left of the clock. Returns false once the flip is over (its clock ran out or its anchor
 * left); the caller ends it (`endRowFlip`).
 */
export function playRowFlip(flip: RowFlip, now: number): boolean {
  const left = flip.until - now;
  if (left <= 0 || !flip.anchor.isConnected) return false;
  for (const [row, state] of flip.rows) {
    if (!row.isConnected) {
      state.move?.cancel();
      flip.rows.delete(row);
      continue;
    }
    const target = placedOffset(row, flip.anchor);
    if (Math.abs(target - state.target) < 0.5) continue;
    // By now the row's box sits at its new place: where it was drawn is its old place plus the part
    // of its motion still playing (the box's offset past its placed top).
    const drawn = state.target + (drawnOffset(row, flip.anchor) - target);
    state.move?.cancel();
    state.move = undefined;
    state.target = target;
    const delta = drawn - target;
    if (Math.abs(delta) < 0.5) continue;
    state.move = row.animate([{ translate: `0 ${delta}px` }, { translate: "0 0" }], {
      duration: left,
      easing: flip.easing,
    });
  }
  return true;
}

/// Ends the flip: every row it moves lands at its place now.
export function endRowFlip(flip: RowFlip | undefined): void {
  if (!flip) return;
  for (const state of flip.rows.values()) state.move?.cancel();
  flip.rows.clear();
}
