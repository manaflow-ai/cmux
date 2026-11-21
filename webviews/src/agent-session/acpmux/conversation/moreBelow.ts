// The bottom edge of a tool output box that scrolls at a fixed height (an MCP call's request and
// response, a tool's Markdown result): `MORE_BELOW` marks it while more of its text lies under that
// edge, and conversation.css fades the edge out, as a cut preview's bottom fades (Leo 2026-10-29:
// "fade is nice ish too on these tool calls"). Scrolled to the end, the mark goes and the last line
// shows whole.
import { useLayoutEffect, useRef, type RefObject } from "react";

/// On a fixed-height output box while text lies under its bottom edge.
export const MORE_BELOW = "data-more-below";

/// Whether `box` has text under its bottom edge (a pixel of slack: zoomed pages and fractional line
/// heights end a scroll a fraction short of the content's height).
export const moreBelow = (box: Element) => box.scrollTop + box.clientHeight < box.scrollHeight - 1;

/// A ref for such a box that keeps `MORE_BELOW` current: once each time `content` changes (a
/// streamed response), on each of its scrolls, and when it or what it holds resizes. Its listener
/// and observer end when the box unmounts or `content` changes; nothing runs while it sits still.
export function useMoreBelow<T extends HTMLElement>(content: unknown) {
  const ref = useRef<T>(null);
  useMoreBelowOn(ref, content);
  return ref;
}

/// The same for a box the caller already holds a ref to (a Shell block's output, which its sideways
/// edge and its follow-the-end watch through the same ref).
export function useMoreBelowOn(ref: RefObject<HTMLElement | null>, content: unknown) {
  useLayoutEffect(() => {
    const box = ref.current;
    if (!box) return;
    const update = () => box.toggleAttribute(MORE_BELOW, moreBelow(box));
    update();
    box.addEventListener("scroll", update, { passive: true });
    const view = box.ownerDocument.defaultView;
    const resize = view?.ResizeObserver ? new view.ResizeObserver(update) : undefined;
    resize?.observe(box);
    if (box.firstElementChild) resize?.observe(box.firstElementChild);
    return () => {
      box.removeEventListener("scroll", update);
      resize?.disconnect();
    };
  }, [ref, content]);
}
