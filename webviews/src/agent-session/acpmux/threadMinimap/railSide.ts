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
import { RAIL_LEFT } from "./model";

export type RailSide = "left" | "right";

/// The rail's edge, its inset from that edge, and the right-click menu's one item: a toggle to the
/// other edge. Moving back to the left removes the key, so the default (left) holds again.
export function useRailSide(): { side: RailSide; inset: React.CSSProperties; menu: ContextMenuItem[] } {
  const t = useT();
  const side = useChatDisplay().railSide;
  return {
    side,
    inset: side === "right" ? { right: RAIL_LEFT } : { left: RAIL_LEFT },
    menu: [
      {
        id: "rail-side",
        label: t(side === "right" ? "minimap.moveLeft" : "minimap.moveRight"),
        onSelect: () => changeChatDisplay(RAIL_SIDE_KEY, side === "right" ? null : "right"),
      },
    ],
  };
}
