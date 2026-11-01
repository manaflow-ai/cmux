import { useCallback, useEffect, useLayoutEffect, useState, type RefObject } from "react";
import { useChatDisplay, useChatMinimap } from "../chatDisplay";
import { MINIMAP_EDGE, MINIMAP_WIDTH } from "../chatMinimap/paint";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing } from "../chatWidth";
import { transcriptColumn } from "../model";
import { experimentArm } from "../../../experiments/experiment";
import { threadMinimapGutter } from "./gutter.experiment";
import { railPlacement } from "./model";
import type { RailSide } from "./railSide";

/// What the pane edge holds outside the rail: on the right, the VS Code minimap (ChatMinimap.tsx) when it
/// is on and has its room, so the right rail sits on its inner side instead of under it. The same gutter
/// test as ChatMinimap's.
export const railEdgeReserve = (side: RailSide, chatMinimap: boolean, textInset: number): number =>
  side === "right" && chatMinimap && textInset >= MINIMAP_WIDTH + 2 * MINIMAP_EDGE ? MINIMAP_WIDTH + MINIMAP_EDGE : 0;

/// The pane edge owns x; the actual remaining text gutter only controls compression and occlusion.
/// Reuses VirtualTranscript's resize measurements and Session Info's layout event. No observer or
/// frame loop, and no DOM work on a streamed token. The scoped listener is removed on unmount.
/// `reserve` is the px at the rail's edge before its own inset (railEdgeReserve); the placement's
/// `gutter` and overlap are measured from there.
export function useRailPlacement(
  scroller: RefObject<HTMLElement | null>,
  paneWidth: number,
  columnWidth: number,
  side: RailSide = "left",
) {
  const display = useChatDisplay();
  const chatMinimap = useChatMinimap();
  const { width: chatWidth, scale } = useChatSizing();
  /// How the rail fits a narrow gutter (gutter.experiment.ts), read once per pane: `tight` lets its
  /// inset shrink to the smallest spacing step before it overlaps any text.
  const [gutterArm] = useState(() => experimentArm(threadMinimapGutter));
  const [placement, setPlacement] = useState(() => ({ ...railPlacement(paneWidth), reserve: 0, gutterArm }));
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
      // Session Info never moves the chat's column (session-info/SessionInfo.tsx), so its inset is the
      // column's own.
      const inset = transcriptColumn(columnWidth, chatColumnOf(chatWidth, display, scale)).inset;
      const reserve = railEdgeReserve(side, chatMinimap, inset);
      const next = {
        ...railPlacement(paneWidth, inset - reserve, {
          min: gutterArm === "tight" ? token("--cmux-space-1", 4) : token("--cmux-space-2", 8),
          max: token("--cmux-space-4", 16),
          compact: token("--cmux-space-3", 12),
          ...(gutterArm === "tight" ? { narrowest: token("--cmux-space-3", 12) } : {}),
        }),
        reserve,
        gutterArm,
      };
      setPlacement((was) =>
        was.left === next.left &&
        was.width === next.width &&
        was.overlapsText === next.overlapsText &&
        was.gutter === next.gutter &&
        was.reserve === next.reserve
          ? was
          : next,
      );
    };
    update();
    return { shell, update };
  }, [scroller, paneWidth, columnWidth, chatWidth, display, scale, side, chatMinimap, gutterArm]);
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
