// Owns navigation between diff items: the item to scroll to, the next or previous item, the item
// in view, and the plain-text form of an item that is presented without highlighting.
import { type CodeViewItemScrollTarget } from "@pierre/diffs";
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

/** The reader's place in the column: the file under the viewport, and how far into it they are. */
export type ItemScrollAnchor = { itemId: string; offset: number };

/**
 * The reader's place as that file and the pixels of it above the viewport's top, so a reorder of
 * the column can put them back on the line they were reading instead of the file's first one.
 *
 * The offset is exactly as true after the reorder as before, and for two reasons rather than one:
 * the column reorders whole files instead of reflowing any of them, and a file's header row is a
 * fixed `DIFF_FILE_HEADER_HEIGHT` (pierre-options.ts gives the virtualizer that number as its
 * `diffHeaderHeight` metric and pins the row to it in the shadow root), so the kind pill the
 * grouping adds to every header cannot change a file's height either. A reviewer of #23649
 * measured the slotted `.file-header`, which is content-sized, and read a two-pixel wobble into
 * it; the row around it is 38px whatever it holds, and `getTopForItem` is built from the declared
 * metric, never from the DOM.
 *
 * `getTopForItem` is the viewer's own measure of where the file starts. A file it cannot measure
 * anchors at its top — what every file did before the offset existed.
 */
export function itemScrollAnchor(
  itemId: string,
  scrollTop: number,
  getTopForItem: (itemId: string) => number | undefined,
): ItemScrollAnchor | null {
  if (!itemId) {
    return null;
  }
  const top = getTopForItem(itemId);
  return { itemId, offset: top == null ? 0 : Math.max(0, scrollTop - top) };
}

/**
 * That anchor as a scroll target. Pierre resolves an item target at align `start` to
 * `top - offset` (CodeView.resolveAlignedScrollPosition), so the pixels that were above the
 * viewport go in negative; it clamps the result, so a file now at the very end of the column
 * lands as close as the column allows rather than out of range.
 */
export function itemScrollTarget(anchor: ItemScrollAnchor): CodeViewItemScrollTarget {
  // `=== 0` rather than plain negation: `-0` is what negating zero gives, and a scroll target
  // carrying `-0` reads as a mistake in every log and comparison it ever lands in.
  const offset = anchor.offset === 0 ? 0 : -anchor.offset;
  return { type: "item", id: anchor.itemId, align: "start", offset, behavior: "instant" };
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
