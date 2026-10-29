// Which edge of the chat the rail sits on (Settings > Agent Chat > Prompt Rail Side, the cmux.json
// key `agentPane.display.rail.side`), and the rail's right-click menu that moves it to the other
// (Leo, 2026-10-22: "an option for moving it the right.. maybe specifically right clicking that area
// (and as a toggle)"). Both rails (ThreadMinimap.tsx, ScrollMap.tsx) read it. On the right the rail
// keeps its 16 px inset from that edge, its ticks grow toward the chat (threadMinimap.css mirrors
// them), and the preview card opens on the rail's left.
import type React from "react";
import { changeChatDisplay, RAIL_SIDE_KEY, useChatDisplay } from "../chatDisplay";
import { useT } from "../i18n";
import type { ContextMenuItem } from "../../../ui/ContextMenu";
import { RAIL_MAX_OVERLAP, ROW_WIDTH } from "./model";
/// The saved right-edge choice keeps its original inset; the left follows the text gutter.
export const RAIL_RIGHT = 16;

export type RailSide = "left" | "right";

/// The left rail's placement already limits overlap; the fixed right inset needs more room.
export const railSideFits = (side: RailSide, gutter: number): boolean =>
  side !== "right" || gutter >= RAIL_RIGHT + ROW_WIDTH - RAIL_MAX_OVERLAP;

/// The unshifted left edge used by the Session Info translation clamp. A right rail is placed from
/// the pane's right edge, so its actual left edge—not the left text gutter—sets the room it can move.
export const railLeftEdge = (side: RailSide, width: number, left: number): number =>
  side === "right" ? Math.max(0, width - RAIL_RIGHT - ROW_WIDTH) : left;

/// The rail's edge, its inset from that edge, and the right-click menu's one item: a toggle to the
/// other edge. Moving back to the left removes the key, so the default (left) holds again.
export function useRailSide(left: number): { side: RailSide; inset: React.CSSProperties; menu: ContextMenuItem[] } {
  const t = useT();
  const side = useChatDisplay().railSide;
  return {
    side,
    inset: side === "right" ? { right: RAIL_RIGHT } : { left },
    menu: [
      {
        id: "rail-side",
        label: t(side === "right" ? "minimap.moveLeft" : "minimap.moveRight"),
        onSelect: () => changeChatDisplay(RAIL_SIDE_KEY, side === "right" ? null : "right"),
      },
    ],
  };
}
