// The timeline's one scroll effect, kept narrow: open a conversation at its newest message, follow
// new messages while the reader is at the bottom, and keep the reading position when older
// messages are prepended (the first row's key changes and the content above grows).
import { useLayoutEffect, useRef } from "react";
import type { Virtualizer } from "@tanstack/react-virtual";

const NEAR_BOTTOM_PX = 48;

export function useStickToBottom(
  virtualizer: Virtualizer<HTMLDivElement, Element>,
  scroller: React.RefObject<HTMLDivElement | null>,
  conversation: string | undefined,
  count: number,
  firstKey: string | undefined,
): { onScroll(): boolean } {
  const state = useRef({
    conversation: undefined as string | undefined,
    count: 0,
    firstKey: undefined as string | undefined,
    total: 0,
    atBottom: true,
  });
  useLayoutEffect(() => {
    const last = state.current;
    const element = scroller.current;
    const total = virtualizer.getTotalSize();
    if (conversation !== last.conversation) {
      if (count > 0) virtualizer.scrollToIndex(count - 1, { align: "end" });
      last.atBottom = true;
    } else if (element && firstKey !== last.firstKey && count > last.count && last.firstKey !== undefined) {
      element.scrollTop += total - last.total;
    } else if (count > last.count && last.atBottom && count > 0) {
      virtualizer.scrollToIndex(count - 1, { align: "end" });
    }
    state.current = { ...last, conversation, count, firstKey, total };
  });
  return {
    /** Records whether the reader is at the bottom; true when the top is reached. */
    onScroll() {
      const element = scroller.current;
      if (!element) return false;
      state.current.atBottom = element.scrollHeight - element.scrollTop - element.clientHeight < NEAR_BOTTOM_PX;
      return element.scrollTop < 200;
    },
  };
}
