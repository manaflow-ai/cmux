// Owns navigation between diff items: the item to scroll to, the next or previous item, the item
// in view, and the plain-text form of an item that is presented without highlighting.
import { type CodeViewHandle } from "@pierre/diffs/react";
import { flushSync } from "react-dom";
import { type DiffItem } from "../diff-stream";

/**
 * Applies `update` and, when it collapses `collapsingItemId` while that file's
 * header is stuck at the top of the viewer (the viewer is scrolled into the
 * file's body), scrolls so the collapsed header stays the top row. Without
 * this the viewer keeps its line anchor into content that no longer exists
 * and lands a few pixels into the previous file. `update` is flushed first
 * so the code view lays out the collapsed item before the scroll resolves.
 */
export function keepStuckHeaderInView(
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>,
  collapsingItemId: string | null,
  update: () => void,
): void {
  const instance = collapsingItemId == null ? null : codeViewRef.current?.getInstance();
  const top = instance == null ? undefined : instance.getTopForItem(collapsingItemId!);
  const stuck = instance != null && typeof top === "number" && top < instance.getScrollTop();
  if (!stuck) {
    update();
    return;
  }
  flushSync(update);
  codeViewRef.current?.scrollTo({ type: "item", id: collapsingItemId!, align: "start", behavior: "instant" });
}

const plainTextItems = new WeakMap<DiffItem, DiffItem>();

/**
 * A collapsed file shows only its header, but @pierre/diffs still sends a
 * mounted collapsed file to the highlight workers (FileDiff.render runs the
 * hunks renderer with an empty range, which queues the whole file). On a
 * large diff that put five collapsed 20,000-line files ahead of the visible
 * file in the worker queue. Presenting a collapsed file as plain text
 * (`lang: "text"`, Pierre's own no-highlight path, with its own cache key)
 * keeps it out of the queue; expanding the file changes the item (a new
 * version), which presents the real language and highlights it then.
 * Cached per item object, so CodeView sees a stable item while it is
 * unchanged.
 */
export function presentedItem(item: DiffItem): DiffItem {
  const diff = item.fileDiff;
  if (!item.collapsed || diff == null || diff.lang === "text") {
    return item;
  }
  let presented = plainTextItems.get(item);
  if (presented == null) {
    presented = { ...item, fileDiff: { ...diff, lang: "text", cacheKey: `${diff.cacheKey ?? item.id}:collapsed` } };
    plainTextItems.set(item, presented);
  }
  return presented;
}

export function scrollTargetForItem(itemId: string, items: DiffItem[]): string {
  if (items.some((item) => item.id === itemId)) {
    return itemId;
  }
  return items[0]?.id ?? "";
}

export function adjacentItemId(activeItemId: string, items: DiffItem[], direction: -1 | 1): string {
  if (items.length === 0) {
    return "";
  }
  const currentIndex = items.findIndex((item) => item.id === activeItemId);
  if (currentIndex < 0) {
    return direction > 0 ? items[0].id : items[items.length - 1].id;
  }
  const targetIndex = currentIndex + direction;
  return targetIndex >= 0 && targetIndex < items.length ? items[targetIndex].id : "";
}

export function visibleItemId(
  items: DiffItem[],
  scrollTop: number,
  getTopForItem: (itemId: string) => number | undefined,
): string {
  let low = 0;
  let high = items.length - 1;
  let visibleIndex = items.length > 0 ? 0 : -1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const top = getTopForItem(items[middle].id);
    if (top != null && top <= scrollTop + 1) {
      visibleIndex = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return visibleIndex >= 0 ? items[visibleIndex].id : "";
}
