/// Where each focused id was found last (`rowPresence`'s `hints`): rows change at their tail, so an
/// id keeps its index from one snapshot to the next, and the check there is O(1).
/// `gone`: an id known to be in none of the rows, by what it was asked for (`rowPresence` found it
/// nowhere, or the caller saw its row taken out and no row with its id come in: `movedHints`), so
/// asking for it again walks nothing.
export type RowPresenceHints = {
  active?: number;
  anchor?: number;
  focus?: number;
  gone?: { active?: string; anchor?: string; focus?: string };
};

const KEYS = ["active", "anchor", "focus"] as const;

/// `hints` for `rows`, made from `base`'s hints where `rows` is `base` with `rows[from, end)` in
/// place of `base[from, baseEnd)` (rowsDelta.ts): a hinted row moves with the rows above it, and
/// an id whose row was taken out, or that was gone, is looked for among the rows that came in only.
/// O(rows that came in). `ids`: what each hint is asked for now.
export function movedHints(
  hints: RowPresenceHints,
  rows: readonly { id: string }[],
  delta: { from: number; end: number; baseEnd: number },
  ids: { active?: string; anchor?: string; focus?: string },
): void {
  const cameIn = (id: string) => {
    for (let index = delta.from; index < delta.end; index += 1) if (rows[index]!.id === id) return index;
    return -1;
  };
  for (const key of KEYS) {
    const id = ids[key];
    const at = hints[key];
    const wasGone = id !== undefined && hints.gone?.[key] === id;
    if (hints.gone) delete hints.gone[key];
    if (at !== undefined && !wasGone) {
      if (at < delta.from) continue;
      if (at >= delta.baseEnd) {
        hints[key] = at + delta.end - delta.baseEnd;
        continue;
      }
    }
    // Taken out (or gone before): only a row that came in can hold it now.
    delete hints[key];
    if (id === undefined || (at === undefined && !wasGone)) continue;
    const found = cameIn(id);
    if (found >= 0) hints[key] = found;
    else (hints.gone ??= {})[key] = id;
  }
}

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
  // An id known gone is not walked for.
  const gone = hints?.gone;
  let seekActive = !active && gone?.active !== activeId;
  let seekAnchor = !anchor && gone?.anchor !== anchorId;
  let seekFocus = !focus && gone?.focus !== focusId;
  for (let index = rows.length - 1; index >= 0 && (seekActive || seekAnchor || seekFocus); index -= 1) {
    const id = rows[index]!.id;
    if (seekActive && id === activeId) {
      active = true;
      seekActive = false;
      if (hints) hints.active = index;
    }
    if (seekAnchor && id === anchorId) {
      anchor = true;
      seekAnchor = false;
      if (hints) hints.anchor = index;
    }
    if (seekFocus && id === focusId) {
      focus = true;
      seekFocus = false;
      if (hints) hints.focus = index;
    }
  }
  // Walked for and found nowhere: gone, until a row with its id comes in (movedHints).
  if (hints) {
    if (!active && activeId !== undefined) (hints.gone ??= {}).active = activeId;
    if (!anchor && anchorId !== undefined) (hints.gone ??= {}).anchor = anchorId;
    if (!focus && focusId !== undefined) (hints.gone ??= {}).focus = focusId;
  }
  return { active, anchor, focus };
}
