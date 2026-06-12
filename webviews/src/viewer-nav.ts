import type { CommentFileDiff } from "./comments/anchor";

type NavItem = {
  id: string;
  fileDiff?: CommentFileDiff | null;
};

export type HunkAnchor = {
  itemId: string;
  itemIndex: number;
  lineNumber: number;
  side: "additions" | "deletions";
};

/**
 * Flattens the streamed diff items into an ordered list of hunk anchors for
 * keyboard navigation (next/previous hunk). Each anchor points at the first
 * line of a hunk on whichever side has content, preferring additions so the
 * viewer lands on the new code.
 */
export function buildHunkAnchors(items: readonly NavItem[]): HunkAnchor[] {
  const anchors: HunkAnchor[] = [];
  items.forEach((item, itemIndex) => {
    for (const hunk of item.fileDiff?.hunks ?? []) {
      if (hunk.additionCount > 0) {
        anchors.push({ itemId: item.id, itemIndex, lineNumber: hunk.additionStart, side: "additions" });
      } else if (hunk.deletionCount > 0) {
        anchors.push({ itemId: item.id, itemIndex, lineNumber: hunk.deletionStart, side: "deletions" });
      }
    }
  });
  return anchors;
}

/**
 * Resolves the anchor index a next/previous-hunk keypress should land on.
 * `currentIndex` is the last navigated anchor (-1 when navigation has not
 * started); when the active file changed since then (`activeItemId` no longer
 * matches), navigation re-seeds from the active file's first hunk so n/p stay
 * coherent with file-level jumps.
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
      // Entering a file via file navigation: n goes to its first hunk.
      return direction === 1 ? seeded : Math.max(0, seeded - 1);
    }
    return direction === 1 ? 0 : anchors.length - 1;
  }
  return Math.min(anchors.length - 1, Math.max(0, currentIndex + direction));
}

/**
 * Resolves the item id a next/previous-file keypress should land on.
 */
export function adjacentItemId(
  items: readonly NavItem[],
  activeItemId: string,
  direction: 1 | -1,
): string | null {
  if (items.length === 0) {
    return null;
  }
  const currentIndex = items.findIndex((item) => item.id === activeItemId);
  if (currentIndex < 0) {
    return items[direction === 1 ? 0 : items.length - 1].id;
  }
  const nextIndex = Math.min(items.length - 1, Math.max(0, currentIndex + direction));
  return nextIndex === currentIndex ? null : items[nextIndex].id;
}
