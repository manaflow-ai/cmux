import { useCallback, useRef } from "react";

// scrollHeight/clientHeight round to CSS pixels independently. A one-pixel difference can be
// rounding rather than a hidden row, and must not dim an otherwise completely visible label.
const EDGE_TOLERANCE = 1;

/// Marks a scroller's edges that have more content past them (`data-fade-top`, `data-fade-bottom`;
/// across, `data-fade-left`, `data-fade-right`), so the CSS fades them: a capped list scrolls under
/// macOS's hidden scrollbars, and the fade is its only sign that rows are out of view. Follows
/// scrolling, the scroller's size and its content's. Returns what stops following.
///
/// `quietWhile`, an attribute name: while the scroller carries it, no edge is marked, whatever its
/// overflow, and the marks come back when it goes. The composer's field carries
/// `data-cmux-scroller-settling` while its box moves to a height its draft fits
/// (composer/fieldGrowth.ts): mid-move the draft overflows only until the move lands, so nothing is
/// past either edge (Lawrence 2026-11-15: "on newline, there is a frame of weirdness": the fade
/// dimmed a one- or two-line draft for the whole growth).
///
/// One read a frame: a content edit or a scroll asks for the coming animation frame, and the edges
/// are read there once, however many edits came before it. Reading scrollHeight in the edit's own
/// task forced a layout of everything dirty on the page, once per edit: a running chat's summary
/// card ticks its subagents' clocks while the transcript beside it is dirty, and each tick laid the
/// chat out again, at a cost that grew with the chat's length. The frame callback runs before its
/// paint, so the fade lands on the frame that shows the edit. A resize marks at once:
/// ResizeObserver runs after the frame's layout, where the read costs nothing, and waiting a frame
/// would paint the old fade on the new size.
export function followScrollEdges(
  node: HTMLElement,
  axis: "y" | "x" = "y",
  { quietWhile }: { quietWhile?: string } = {},
): () => void {
  const quiet = () => quietWhile !== undefined && node.hasAttribute(quietWhile);
  const mark =
    axis === "y"
      ? () => {
          if (quiet()) {
            node.removeAttribute("data-fade-top");
            node.removeAttribute("data-fade-bottom");
            return;
          }
          const past = Math.max(0, node.scrollHeight - node.clientHeight);
          const above = Math.min(past, Math.max(0, node.scrollTop));
          node.toggleAttribute("data-fade-top", above > EDGE_TOLERANCE);
          node.toggleAttribute("data-fade-bottom", past - above > EDGE_TOLERANCE);
        }
      : () => {
          if (quiet()) {
            node.removeAttribute("data-fade-left");
            node.removeAttribute("data-fade-right");
            return;
          }
          const past = Math.max(0, node.scrollWidth - node.clientWidth);
          // Right to left, scrollLeft runs from 0 at the right edge down to -past at the left one.
          const offset = getComputedStyle(node).direction === "rtl" ? past + node.scrollLeft : node.scrollLeft;
          const left = Math.min(past, Math.max(0, offset));
          node.toggleAttribute("data-fade-left", left > EDGE_TOLERANCE);
          node.toggleAttribute("data-fade-right", past - left > EDGE_TOLERANCE);
        };
  // A DOM with no frames (the unit tests' fake platforms) reads in the edit's task, as before.
  const framed = typeof requestAnimationFrame === "function" && typeof cancelAnimationFrame === "function";
  let frame: number | undefined;
  const markNow = () => {
    if (frame !== undefined) cancelAnimationFrame(frame);
    frame = undefined;
    mark();
  };
  const markAtFrame = framed
    ? () => {
        frame ??= requestAnimationFrame(() => {
          frame = undefined;
          mark();
        });
      }
    : mark;
  const resize = new ResizeObserver(framed ? markNow : mark);
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
    let quietChanged = false;
    for (const record of records) {
      if (record.type === "attributes") quietChanged = true;
      // Descendant edits can alter scrollHeight without resizing a capped/grid-stretched
      // direct child. Remeasure them, but only update resize targets for our outer boxes.
      if (record.type !== "childList" || (record.target !== node && !boxless.has(record.target as Element))) continue;
      for (const child of record.addedNodes) watchChild(child);
      for (const child of record.removedNodes) unwatchChild(child);
    }
    // The quiet attribute flips inside a frame's own callbacks (composer/fieldGrowth.ts), where a
    // frame request would land a frame late and paint the stale fade it exists to hide.
    if (quietChanged && framed) markNow();
    else markAtFrame();
  });
  content.observe(node, {
    childList: true,
    subtree: true,
    characterData: true,
    ...(quietWhile ? { attributes: true, attributeFilter: [quietWhile] } : {}),
  });
  // A scroll event runs in a frame's scroll steps, before its animation frame callbacks, so the
  // frame it asks for is that same frame: the fade follows the scroll with no lag.
  node.addEventListener("scroll", markAtFrame, { passive: true });
  mark();
  return () => {
    if (frame !== undefined) cancelAnimationFrame(frame);
    frame = undefined;
    resize.disconnect();
    content.disconnect();
    children.clear();
    boxless.clear();
    node.removeEventListener("scroll", markAtFrame);
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
