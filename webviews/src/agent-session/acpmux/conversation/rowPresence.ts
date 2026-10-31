/**
 * Finds the focused transcript ids in one reverse walk. Focus normally stays near the tail, so
 * streaming snapshots stop as soon as the live row and selection endpoints are found. Keeping the
 * three flags separate also avoids allocating a Set for a membership check that has at most three
 * keys.
 */
export function rowPresence(
  rows: readonly { id: string }[],
  activeId: string | undefined,
  anchorId: string | undefined,
  focusId: string | undefined,
): { active: boolean; anchor: boolean; focus: boolean } {
  let active = activeId === undefined;
  let anchor = anchorId === undefined;
  let focus = focusId === undefined;
  for (let index = rows.length - 1; index >= 0 && (!active || !anchor || !focus); index -= 1) {
    const id = rows[index]!.id;
    if (!active && id === activeId) active = true;
    if (!anchor && id === anchorId) anchor = true;
    if (!focus && id === focusId) focus = true;
  }
  return { active, anchor, focus };
}
