import { useCallback, useRef } from "react";

/// Marks a scroller's edges that have more content past them (`data-fade-top`, `data-fade-bottom`),
/// so the CSS fades them: a capped list scrolls under macOS's hidden scrollbars, and the fade is its
/// only sign that rows are out of view. Follows scrolling, the scroller's size and its content's.
/// Returns what stops following.
export function followScrollEdges(node: HTMLElement): () => void {
  const mark = () => {
    const below = node.scrollHeight - node.clientHeight - node.scrollTop;
    node.toggleAttribute("data-fade-top", node.scrollTop > 0.5);
    node.toggleAttribute("data-fade-bottom", below > 0.5);
  };
  // DOM stand-ins without layout (the jsdom and happy-dom unit tests) have no ResizeObserver.
  const resize = typeof ResizeObserver === "function" ? new ResizeObserver(mark) : undefined;
  resize?.observe(node);
  for (const child of node.children) resize?.observe(child);
  const content = new MutationObserver(() => {
    for (const child of node.children) resize?.observe(child);
    mark();
  });
  content.observe(node, { childList: true });
  node.addEventListener("scroll", mark, { passive: true });
  mark();
  return () => {
    resize?.disconnect();
    content.disconnect();
    node.removeEventListener("scroll", mark);
  };
}

/// `followScrollEdges` as a callback ref for the scroller.
export function useScrollEdges(): (node: HTMLElement | null) => void {
  const stop = useRef<(() => void) | undefined>(undefined);
  return useCallback((node: HTMLElement | null) => {
    stop.current?.();
    stop.current = node ? followScrollEdges(node) : undefined;
  }, []);
}
