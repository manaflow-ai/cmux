import { useLayoutEffect, useState, type RefObject } from "react";
import { useChatDisplay } from "../chatDisplay";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatWidth } from "../chatWidth";
import { transcriptColumn } from "../model";
import { railPlacement } from "./model";

/// The pane edge owns x; the actual remaining text gutter only controls compression and occlusion.
/// Reuses VirtualTranscript's resize measurements and the Inspector's layout event. No observer or
/// frame loop, and no DOM work on a streamed token. The scoped listener is removed on unmount.
export function useRailPlacement(scroller: RefObject<HTMLElement | null>, paneWidth: number, columnWidth: number) {
  const display = useChatDisplay();
  const chatWidth = useChatWidth();
  const [placement, setPlacement] = useState(() => railPlacement(paneWidth));
  useLayoutEffect(() => {
    const node = scroller.current;
    const shell = node?.closest<HTMLElement>(".acpmux-shell");
    const update = () => {
      const style = node?.ownerDocument.defaultView?.getComputedStyle(node);
      const token = (name: string, fallback: number) =>
        Number.parseFloat(style?.getPropertyValue(name) ?? "") || fallback;
      const shift = Number.parseFloat(shell?.style.getPropertyValue("--acpmux-chat-shift") ?? "") || 0;
      const inset = transcriptColumn(columnWidth, chatColumnOf(chatWidth, display)).inset - shift;
      const next = railPlacement(paneWidth, inset, {
        min: token("--cmux-space-2", 8),
        max: token("--cmux-space-4", 16),
        compact: token("--cmux-space-3", 12),
      });
      setPlacement((was) =>
        was.left === next.left && was.width === next.width && was.overlapsText === next.overlapsText ? was : next,
      );
    };
    update();
    shell?.addEventListener(CHAT_LAYOUT_EVENT, update);
    return () => shell?.removeEventListener(CHAT_LAYOUT_EVENT, update);
  }, [scroller, paneWidth, columnWidth, chatWidth, display]);
  return placement;
}
