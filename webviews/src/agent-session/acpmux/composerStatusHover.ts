// The composer status dot's hover pieces (composerStatusCard.tsx's seam, its non-components): the hover
// bridge and its timings (ui/hoverIntent.ts), the warm tooltip group, focus after Escape, and the keycap.
import { HOVER_INTENT, HoverBridge, tooltipGroup, type HoverBridgeOptions } from "../../ui/hoverIntent";
import { focusAfterEscape } from "../../ui/escapeFocus";
import { Keycap } from "./Keycap";

export { HOVER_INTENT, HoverBridge, Keycap, focusAfterEscape };
export type { HoverBridgeOptions };

/// Whether a tooltip showed a moment ago: the dot's peek then opens at once, as a warm hint does.
export function tooltipsWarm(): boolean {
  return tooltipGroup.warm;
}
