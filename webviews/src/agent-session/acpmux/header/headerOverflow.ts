import { useLayoutEffect, useRef, useState, type RefObject } from "react";

/// One quick-action button's share of the row: its 24px square and the 2px gap (header.css).
export const HEADER_TOOL_PITCH = 26;

/// The room the header's leading part keeps beside the tools: the title, or the pane's tabs when
/// the tools sit in the tab row (header/tabRow.ts), so a narrow pane still shows one of them.
export const HEADER_LEADING_RESERVE = 120;

/// How many of the `count` trailing quick-action buttons fold into "..." so the tools fit `room`
/// (the header's content width less the leading reserve). `toolsWidth` is the tools' width with
/// `folded` buttons already folded, so the answer does not depend on the last one: no flip-flop
/// at the edge (Leo 2026-10-24: "they're cut off here ... things dont get cut off, things look
/// proper when you have multiple tabs").
export function headerFoldCount(toolsWidth: number, folded: number, room: number, count: number): number {
  const full = toolsWidth + folded * HEADER_TOOL_PITCH;
  if (count <= 0 || full <= room) return 0;
  return Math.min(count, Math.ceil((full - room) / HEADER_TOOL_PITCH));
}

const px = (value: string) => Number.parseFloat(value) || 0;

/// The number of trailing quick-action buttons that do not fit the header the `tools` ref sits
/// in. Event-driven: a ResizeObserver on the header and its trailing group, ended on unmount.
export function useHeaderFold(tools: RefObject<HTMLElement | null>, count: number): number {
  const [fold, setFold] = useState(0);
  const folded = useRef(0);
  folded.current = Math.min(fold, count);
  useLayoutEffect(() => {
    // The header's row holds the tools inside its trailing group (App's presence stack and inline
    // status beside them): that group is what must fit. Outside a chat header (a gallery frame
    // that sizes to its content) nothing folds: there is no pane edge to cut the tools off.
    let element = tools.current;
    const header = element?.closest<HTMLElement>(".acpmux-header");
    while (element && header && element.parentElement !== header) element = element.parentElement;
    if (!element || !header || count <= 0 || typeof ResizeObserver === "undefined") {
      setFold(0);
      return;
    }
    const measure = () => {
      // A header not laid out (a hidden pane) has no width to fit: fold nothing until it shows.
      if (header.clientWidth <= 0) return setFold(0);
      const style = getComputedStyle(header);
      const room =
        header.clientWidth -
        px(style.paddingLeft) -
        px(style.paddingRight) -
        px(style.columnGap) -
        HEADER_LEADING_RESERVE;
      const width = element.getBoundingClientRect().width;
      setFold(headerFoldCount(width, folded.current, room, count));
    };
    const observer = new ResizeObserver(measure);
    observer.observe(header);
    observer.observe(element);
    measure();
    return () => observer.disconnect();
  }, [tools, count]);
  return Math.min(fold, count);
}
