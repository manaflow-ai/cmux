// The one seam between the composer status dot (ComposerStatusDot.tsx) and the pane's shared hover
// card pieces: the glass card (ui/Tooltip.tsx AnchoredCard, its see-through blur), the hover bridge and
// its timings (ui/hoverIntent.ts), the warm tooltip group, focus after Escape, and the keycap. The dot
// imports none of them directly, so a change to how cards look or hover lands here once.
import type { ReactNode, Ref } from "react";
import { AnchoredCard } from "../../ui/Tooltip";
import { hoverCardGlass, hoverCardUnder } from "../../ui/glass/hoverCardGlass";
import { HOVER_INTENT, HoverBridge, tooltipGroup, type HoverBridgeOptions } from "../../ui/hoverIntent";
import { focusAfterEscape } from "../../ui/escapeFocus";
import { Keycap } from "./Keycap";

export { HOVER_INTENT, HoverBridge, Keycap, focusAfterEscape };
export type { HoverBridgeOptions };

/// Whether a tooltip showed a moment ago: the dot's peek then opens at once, as a warm hint does.
export function tooltipsWarm(): boolean {
  return tooltipGroup.warm;
}

/// The rundown card: the pane's glass hover card, interactive (a dialog, never modal), above the dot.
/// The same element serves the peek and the pin, so pinning never moves or redraws it.
export function StatusCard({
  id,
  anchor,
  open,
  pinned,
  label,
  popupRef,
  onPointerEnter,
  onPointerLeave,
  hoverBridgeId,
  children,
}: {
  id: string;
  anchor: HTMLElement | null;
  open: boolean;
  pinned: boolean;
  label: string;
  popupRef: Ref<HTMLDivElement>;
  onPointerEnter?: () => void;
  onPointerLeave?: () => void;
  hoverBridgeId?: number;
  children: ReactNode;
}) {
  return (
    <AnchoredCard
      id={id}
      anchor={anchor}
      open={open && anchor !== null}
      side="top"
      className="acpmux-status-card"
      state={pinned ? "pinned" : "peek"}
      interactive
      ariaLabel={label}
      popupRef={popupRef}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      hoverBridgeId={hoverBridgeId}
      under={hoverCardUnder}
      underOptions={hoverCardGlass}
    >
      {children}
    </AnchoredCard>
  );
}
