// Priority+ overflow model for the diff-viewer toolbar.
//
// The toolbar has an always-present zone (source select + Base picker + the "..."
// options button) plus a set of optional accessory controls that move into the
// "..." menu when the measured toolbar width cannot fit them. This module is the
// pure decision layer: given the measured width, the reserved always-present
// width, and a priority-ordered list of optional items with estimated widths, it
// returns which optional items fit in the bar and which overflow into the menu.
//
// Items are listed HIGH priority first. They are dropped LOW priority first: the
// last item in the list is the first to leave the bar. This keeps the model a
// single greedy pass with no pixel thresholds baked in.

export type ToolbarOverflowItem<Id extends string = string> = {
  /** Stable id of the control (e.g. "files-toggle"). */
  id: Id;
  /** Estimated rendered width in px, including its share of the inter-item gap. */
  width: number;
};

export type ToolbarOverflowInput<Id extends string = string> = {
  /** Measured inner width of the #toolbar element, in px. */
  available: number;
  /**
   * Width reserved for controls that are always in the bar (source select +
   * Base picker + the "..." button). The optional items compete for whatever
   * width remains after this reservation.
   */
  reserved: number;
  /** Optional controls, HIGH priority first (last = first to overflow). */
  items: readonly ToolbarOverflowItem<Id>[];
};

export type ToolbarOverflowResult<Id extends string = string> = {
  /** Ids that fit and should render in the bar, in input order. */
  visible: Id[];
  /** Ids that did not fit and must be reachable from the "..." menu. */
  overflow: Id[];
};

/**
 * Greedily keep the highest-priority optional items that fit in
 * `available - reserved`, dropping the lowest-priority items (end of the list)
 * first. Pure and total: a non-finite or negative budget simply overflows
 * everything, and the caller's CSS `overflow: clip` is the real no-overlap
 * guarantee, so estimation error here can never produce an overlap.
 */
export function resolveToolbarOverflow<Id extends string>(
  input: ToolbarOverflowInput<Id>,
): ToolbarOverflowResult<Id> {
  const budget = (Number.isFinite(input.available) ? input.available : 0) - input.reserved;
  const visible: Id[] = [];
  const overflow: Id[] = [];
  let used = 0;
  let dropping = false;
  for (const item of input.items) {
    const next = used + Math.max(0, item.width);
    if (!dropping && next <= budget) {
      used = next;
      visible.push(item.id);
    } else {
      // Once one item is dropped, drop all lower-priority items too: keeping a
      // smaller later item while a larger earlier one overflowed would reorder
      // priority. This makes overflow a clean priority suffix.
      dropping = true;
      overflow.push(item.id);
    }
  }
  return { visible, overflow };
}
