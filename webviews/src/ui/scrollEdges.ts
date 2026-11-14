import { useCallback, useRef } from "react";

// scrollHeight/clientHeight round to CSS pixels independently. A one-pixel difference can be
// rounding rather than a hidden row, and must not dim an otherwise completely visible label.
const EDGE_TOLERANCE = 1;

/// Marks a scroller's edges that have more content past them (`data-fade-top`, `data-fade-bottom`;
/// across, `data-fade-left`, `data-fade-right`), so the CSS fades them: a capped list scrolls under
/// macOS's hidden scrollbars, and the fade is its only sign that rows are out of view. Follows
/// scrolling, the scroller's size and its content's. Returns what stops following.
export function followScrollEdges(node: HTMLElement, axis: "y" | "x" = "y"): () => void {
  const mark =
    axis === "y"
      ? () => {
          const past = Math.max(0, node.scrollHeight - node.clientHeight);
          const above = Math.min(past, Math.max(0, node.scrollTop));
          node.toggleAttribute("data-fade-top", above > EDGE_TOLERANCE);
          node.toggleAttribute("data-fade-bottom", past - above > EDGE_TOLERANCE);
        }
      : () => {
          const past = Math.max(0, node.scrollWidth - node.clientWidth);
          // Right to left, scrollLeft runs from 0 at the right edge down to -past at the left one.
          const offset = getComputedStyle(node).direction === "rtl" ? past + node.scrollLeft : node.scrollLeft;
          const left = Math.min(past, Math.max(0, offset));
          node.toggleAttribute("data-fade-left", left > EDGE_TOLERANCE);
          node.toggleAttribute("data-fade-right", past - left > EDGE_TOLERANCE);
        };
  const resize = new ResizeObserver(mark);
  resize.observe(node);
  const children = new Set<Element>();
  const boxless = new Set<Element>();
  const watchChild = (child: Node) => {
    if (child.nodeType !== 1) return;
    const element = child as Element;
    // A child that draws no box of its own (display: contents, the attachment strip's slots)
    // never resizes: its children are the ones laid out in the row.
    const style = element.ownerDocument?.defaultView?.getComputedStyle?.(element);
    if (style?.display === "contents") {
      boxless.add(element);
      for (const inner of element.children ?? []) watchChild(inner);
      return;
    }
    if (children.has(element)) return;
    children.add(element);
    resize.observe(element);
  };
  const unwatchChild = (child: Node) => {
    if (child.nodeType !== 1) return;
    const element = child as Element;
    if (!children.delete(element)) {
      // A boxless child was never watched itself: its children were.
      if (boxless.delete(element)) for (const inner of element.children ?? []) unwatchChild(inner);
      return;
    }
    resize.unobserve(element);
  };
  for (const child of node.children) watchChild(child);
  const content = new MutationObserver((records) => {
    for (const record of records) {
      // Descendant edits can alter scrollHeight without resizing a capped/grid-stretched
      // direct child. Remeasure them, but only update resize targets for our outer boxes.
      if (record.type !== "childList" || (record.target !== node && !boxless.has(record.target as Element))) continue;
      for (const child of record.addedNodes) watchChild(child);
      for (const child of record.removedNodes) unwatchChild(child);
    }
    mark();
  });
  content.observe(node, { childList: true, subtree: true, characterData: true });
  node.addEventListener("scroll", mark, { passive: true });
  mark();
  return () => {
    resize.disconnect();
    content.disconnect();
    children.clear();
    boxless.clear();
    node.removeEventListener("scroll", mark);
  };
}

/// `followScrollEdges` as a callback ref for the scroller. A DOM with no layout (the jsdom and
/// happy-dom unit tests) may have no observers, and nothing scrolls there.
export function useScrollEdges(axis: "y" | "x" = "y"): (node: HTMLElement | null) => void {
  const stop = useRef<(() => void) | undefined>(undefined);
  return useCallback(
    (node: HTMLElement | null) => {
      stop.current?.();
      stop.current =
        node && typeof ResizeObserver === "function" && typeof MutationObserver === "function"
          ? followScrollEdges(node, axis)
          : undefined;
    },
    [axis],
  );
}
