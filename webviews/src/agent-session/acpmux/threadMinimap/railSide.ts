// Which edge of the chat the rail sits on (Settings > Agent Chat > Prompt Rail Side, the cmux.json
// key `agentPane.display.rail.side`), and the rail's right-click menu that moves it to the other
// (Leo, 2026-10-22: "an option for moving it the right.. maybe specifically right clicking that area
// (and as a toggle)" and "default on, default left?"). Both rails (ThreadMinimap.tsx, ScrollMap.tsx)
// read it. The right rail is the left one mirrored (design/session-rail.md): the same pane-edge inset
// (useRailPlacement) counted from the pane's right edge, the same narrow-pane hover strip at that edge,
// its ticks growing toward the text (threadMinimap.css), and its preview card opening on its left.
import type React from "react";
import { changeChatDisplay, RAIL_SIDE_KEY, useChatDisplay } from "../chatDisplay";
import { useT } from "../i18n";
import type { ContextMenuItem } from "../../../ui/ContextMenu";

export type RailSide = "left" | "right";

/// The CSS that pins a box `inset` px in from the rail's edge of the pane.
export const railEdge = (side: RailSide, inset: number): React.CSSProperties =>
  side === "right" ? { right: inset } : { left: inset };

/// The rail's edge and the right-click menu's one item: a toggle to the other edge. Moving back to
/// the left removes the key, so the default (left) holds again.
export function useRailSide(): { side: RailSide; menu: ContextMenuItem[] } {
  const t = useT();
  const side = useChatDisplay().railSide;
  return {
    side,
    menu: [
      {
        id: "rail-side",
        label: t(side === "right" ? "minimap.moveLeft" : "minimap.moveRight"),
        onSelect: () => changeChatDisplay(RAIL_SIDE_KEY, side === "right" ? null : "right"),
      },
    ],
  };
}
