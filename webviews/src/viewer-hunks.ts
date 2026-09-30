import type { CommentFileDiff } from "./comments/anchor";

type HunkNavItem = {
  id: string;
  fileDiff?: CommentFileDiff | null;
};

export type HunkAnchor = {
  itemId: string;
  lineNumber: number;
  side: "additions" | "deletions";
};

/**
 * Flattens the streamed diff items into an ordered list of hunk anchors for
 * keyboard navigation (next/previous hunk). Each anchor points at the first
 * line of a hunk on whichever side has content, preferring additions so the
 * viewer lands on the new code.
 */
export function buildHunkAnchors(items: readonly HunkNavItem[]): HunkAnchor[] {
  const anchors: HunkAnchor[] = [];
  for (const item of items) {
    for (const hunk of item.fileDiff?.hunks ?? []) {
      if (hunk.additionCount > 0) {
        anchors.push({ itemId: item.id, lineNumber: hunk.additionStart, side: "additions" });
      } else if (hunk.deletionCount > 0) {
        anchors.push({ itemId: item.id, lineNumber: hunk.deletionStart, side: "deletions" });
      }
    }
  }
  return anchors;
}

/**
 * Resolves the anchor index a next/previous-hunk keypress should land on.
 * `currentIndex` is the last navigated anchor (-1 when hunk navigation has
 * not started). When the active file changed since then (`activeItemId` no
 * longer matches), navigation re-seeds from the active file's first hunk so
 * n/p stay coherent with file-level jumps; a file without hunks re-seeds from
 * the diff edges.
 */
export function nextHunkIndex(
  anchors: readonly HunkAnchor[],
  currentIndex: number,
  activeItemId: string,
  direction: 1 | -1,
): number {
  if (anchors.length === 0) {
    return -1;
  }
  const current = currentIndex >= 0 && currentIndex < anchors.length ? anchors[currentIndex] : null;
  if (current == null || (activeItemId !== "" && current.itemId !== activeItemId)) {
    const seeded = anchors.findIndex((anchor) => anchor.itemId === activeItemId);
    if (seeded >= 0) {
      return direction === 1 ? seeded : Math.max(0, seeded - 1);
    }
    return direction === 1 ? 0 : anchors.length - 1;
  }
  return Math.min(anchors.length - 1, Math.max(0, currentIndex + direction));
}
