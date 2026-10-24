/**
 * Finds the focused transcript ids in one pass. Keeping the three flags separate avoids allocating
 * a Set for a membership check that has at most three keys.
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
  for (const row of rows) {
    const id = row.id;
    if (!active && id === activeId) active = true;
    if (!anchor && id === anchorId) anchor = true;
    if (!focus && id === focusId) focus = true;
  }
  return { active, anchor, focus };
}
