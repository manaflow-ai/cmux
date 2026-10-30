import { useCallback, useEffect, useLayoutEffect, useState, type RefObject } from "react";
import { useChatDisplay } from "../chatDisplay";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing } from "../chatWidth";
import { transcriptColumn } from "../model";
import { railPlacement } from "./model";

/// The pane edge owns x; the actual remaining text gutter only controls compression and occlusion.
/// Reuses VirtualTranscript's resize measurements and the Inspector's layout event. No observer or
/// frame loop, and no DOM work on a streamed token. The scoped listener is removed on unmount.
export function useRailPlacement(scroller: RefObject<HTMLElement | null>, paneWidth: number, columnWidth: number) {
  const display = useChatDisplay();
  const { width: chatWidth, scale } = useChatSizing();
  const [placement, setPlacement] = useState(() => railPlacement(paneWidth));
  // The layout effect places the rail before paint when the scroller is already attached. On a mount
  // the child effect runs before the ancestor scroller's ref is set, so the passive effect, which
  // runs after every ref is attached, measures again and subscribes to the shell's layout event.
  const measure = useCallback(() => {
    const node = scroller.current;
    if (!node) return undefined;
    const shell = node.closest<HTMLElement>(".acpmux-shell");
    const update = () => {
      const style = node.ownerDocument.defaultView?.getComputedStyle(node);
      const token = (name: string, fallback: number) =>
        Number.parseFloat(style?.getPropertyValue(name) ?? "") || fallback;
      // Session Info never moves the chat's column (inspector/ChatInspector.tsx), so its inset is the
      // column's own.
      const inset = transcriptColumn(columnWidth, chatColumnOf(chatWidth, display, scale)).inset;
      const next = railPlacement(paneWidth, inset, {
        min: token("--cmux-space-2", 8),
        max: token("--cmux-space-4", 16),
        compact: token("--cmux-space-3", 12),
      });
      setPlacement((was) =>
        was.left === next.left &&
        was.width === next.width &&
        was.overlapsText === next.overlapsText &&
        was.gutter === next.gutter
          ? was
          : next,
      );
    };
    update();
    return { shell, update };
  }, [scroller, paneWidth, columnWidth, chatWidth, display, scale]);
  useLayoutEffect(() => {
    measure();
  }, [measure]);
  useEffect(() => {
    const placed = measure();
    if (!placed?.shell) return;
    const { shell, update } = placed;
    shell.addEventListener(CHAT_LAYOUT_EVENT, update);
    return () => shell.removeEventListener(CHAT_LAYOUT_EVENT, update);
  }, [measure]);
  return placement;
}
