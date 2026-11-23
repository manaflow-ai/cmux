import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { TAB_ROW_GAP } from "./tabRow";

/// One quick-action button's share of the row at the default interface size: its 24px square and
/// the 2px gap (header.css). useHeaderFold measures the real pitch, which scales with the interface
/// and the density; this is the fallback before a tool is laid out.
export const HEADER_TOOL_PITCH = 26;

/// The room the header's leading part keeps beside the tools: the title, or the pane's tabs when
/// the tools sit in the tab row (header/tabRow.ts), so a narrow pane still shows one of them.
export const HEADER_LEADING_RESERVE = 120;

/// How many of the `count` trailing quick-action buttons fold into "..." so the tools fit `room`
/// (the header's content width less the leading reserve). `toolsWidth` is the tools' width with
/// `folded` buttons already folded, so the answer does not depend on the last one: no flip-flop
/// at the edge (Leo 2026-10-24: "they're cut off here ... things dont get cut off, things look
/// proper when you have multiple tabs").
export function headerFoldCount(
  toolsWidth: number,
  folded: number,
  room: number,
  count: number,
  pitch = HEADER_TOOL_PITCH,
): number {
  const step = pitch > 0 ? pitch : HEADER_TOOL_PITCH;
  const full = toolsWidth + folded * step;
  if (count <= 0 || full <= room) return 0;
  return Math.min(count, Math.ceil((full - room) / step));
}

/// The room the trailing group may take in a header `content` wide (its padding out). In its own row: all but the
/// leading reserve. In the pane's tab row also at most half of it, less the gap the page adds to the width it reports:
/// the App offers the row only while the tools take at most half (CmuxNextDesign `PaneTabRowSharing.fitsTabRow`), and
/// tools wider than that dropped to a second row under the tabs, moving every button down (Leo, 2026-11-23: "the
/// fucking buttons on the top right NEED to be done right, especially when things are at compressed width panes").
/// Folding a quick action into "..." first keeps them in the row.
export function headerFoldRoom(content: number, gap: number, tabRow: boolean): number {
  const own = content - gap - HEADER_LEADING_RESERVE;
  return tabRow ? Math.min(own, Math.floor(content / 2) - TAB_ROW_GAP) : own;
}

/// One tool's square plus the gap after it, as laid out now: the pitch grows with the interface
/// size and the density (Leo 2026-11-04: "so all those things are proportional").
/// Only a square tool counts: the worktree pill, the PR chip and a counted inbox share the
/// .acpmux-header-tool class at their text's width, and a pitch read from them would keep buttons
/// folded long after the pane widens. With every quick action folded, the "..." square stands in.
export function measuredPitch(tools: HTMLElement): number {
  const tool =
    tools.querySelector<HTMLElement>("[data-quick-action]") ?? tools.querySelector<HTMLElement>(".acpmux-header-more");
  if (!tool) return HEADER_TOOL_PITCH;
  const width = tool.getBoundingClientRect().width;
  return width > 0 ? width + px(getComputedStyle(tools).columnGap) : HEADER_TOOL_PITCH;
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
      const content = header.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
      const room = headerFoldRoom(content, px(style.columnGap), header.hasAttribute("data-tab-row"));
      const width = element.getBoundingClientRect().width;
      const pitch = tools.current ? measuredPitch(tools.current) : HEADER_TOOL_PITCH;
      setFold(headerFoldCount(width, folded.current, room, count, pitch));
    };
    const observer = new ResizeObserver(measure);
    observer.observe(header);
    observer.observe(element);
    measure();
    return () => observer.disconnect();
  }, [tools, count]);
  return Math.min(fold, count);
}
