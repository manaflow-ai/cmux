/// Where each focused id was found last (`rowPresence`'s `hints`): rows change at their tail, so an
/// id keeps its index from one snapshot to the next, and the check there is O(1).
export type RowPresenceHints = { active?: number; anchor?: number; focus?: number };

/**
 * Finds the focused transcript ids in one reverse walk. Focus normally stays near the tail, so
 * streaming snapshots stop as soon as the live row and selection endpoints are found. Keeping the
 * three flags separate also avoids allocating a Set for a membership check that has at most three
 * keys. With `hints` (kept by the caller across calls), an id still at the index it was found at
 * last is found there first: the roving tab stop is the first row in view, which for a reader at
 * the latest message of a long chat is far from the tail, and walking to it on every streamed
 * token made each token's work grow with the transcript.
 */
export function rowPresence(
  rows: readonly { id: string }[],
  activeId: string | undefined,
  anchorId: string | undefined,
  focusId: string | undefined,
  hints?: RowPresenceHints,
): { active: boolean; anchor: boolean; focus: boolean } {
  const at = (id: string | undefined, hint: number | undefined) =>
    id === undefined || (hint !== undefined && rows[hint]?.id === id);
  let active = at(activeId, hints?.active);
  let anchor = at(anchorId, hints?.anchor);
  let focus = at(focusId, hints?.focus);
  for (let index = rows.length - 1; index >= 0 && (!active || !anchor || !focus); index -= 1) {
    const id = rows[index]!.id;
    if (!active && id === activeId) {
      active = true;
      if (hints) hints.active = index;
    }
    if (!anchor && id === anchorId) {
      anchor = true;
      if (hints) hints.anchor = index;
    }
    if (!focus && id === focusId) {
      focus = true;
      if (hints) hints.focus = index;
    }
  }
  return { active, anchor, focus };
}
