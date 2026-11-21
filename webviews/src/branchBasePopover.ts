// Where the diff viewer's Base picker popover (BranchBasePicker.tsx) sits: under (or above) the Base
// button, clamped to the viewport. Every length here is the stylesheet's (`.base-picker-popover`,
// styles.css) at the interface scale, so the clamp reckons with the width the popover draws at the
// person's Text Size, not the 320 px it has at the default (Leo, 2026-11-12: "it doesn't follow").
import type { CSSProperties } from "react";
import { interfaceScale } from "./ui/interfaceScale";

// Inline `position: fixed` style for the popover, recomputed from the Base button's viewport rect.
// Only the fields the popover needs to override. When flipped above the button, `top` is `auto` and
// `bottom` anchors it to just above the button so a short popover stays glued to the button, not
// the viewport top.
export type PopoverStyle = Pick<CSSProperties, "top" | "bottom" | "left" | "maxHeight">;

// Popover sizing at the default Text Size, CSS px. Width and cap match `.base-picker-popover`
// (`calc(320 * var(--ui-px))`, `max-width: min(86vw, calc(360 * var(--ui-px)))`).
export const POPOVER_WIDTH = 320;
const POPOVER_MAX_WIDTH = 360;
const POPOVER_MAX_WIDTH_VW = 0.86;
export const POPOVER_GAP = 6;
// Keep at least this much breathing room from each viewport edge.
export const VIEWPORT_MARGIN = 8;
// Don't bother flipping above unless the popover can be at least this tall there.
export const POPOVER_MIN_HEIGHT = 160;

/** The popover's drawn width at `scale` in a viewport `viewportWidth` wide, as its stylesheet sizes it. */
export function popoverWidth(scale: number, viewportWidth: number): number {
  return Math.min(POPOVER_WIDTH * scale, POPOVER_MAX_WIDTH * scale, viewportWidth * POPOVER_MAX_WIDTH_VW);
}

// Anchor the fixed popover under (or above) the Base button, clamped to the viewport. Horizontal:
// align to the button's left edge, but shift left so the popover never overruns the right edge.
// Vertical: prefer below the button; flip above when there is more room there, and cap max-height
// to the space available on the chosen side so the list scrolls instead of overflowing the
// viewport. The popover is portaled to `document.body`, so this fixed element resolves against the
// viewport, escaping the toolbar cell's container-query containing block and its `overflow-x: clip`.
export function computePopoverStyle(rect: DOMRect, view: Window = window): PopoverStyle {
  const viewportWidth = view.innerWidth;
  const viewportHeight = view.innerHeight;
  const scale = interfaceScale(view);
  const gap = POPOVER_GAP * scale;
  const margin = VIEWPORT_MARGIN * scale;
  const minHeight = POPOVER_MIN_HEIGHT * scale;

  const maxLeft = viewportWidth - popoverWidth(scale, viewportWidth) - margin;
  const left = Math.max(margin, Math.min(rect.left, maxLeft));

  const spaceBelow = viewportHeight - rect.bottom - gap - margin;
  const spaceAbove = rect.top - gap - margin;
  // Flip above only when below is too cramped AND above is genuinely roomier.
  const flipAbove = spaceBelow < minHeight && spaceAbove > spaceBelow;

  if (flipAbove) {
    return {
      top: "auto",
      // Anchor the popover's bottom one gap above the button top; it grows upward and a short
      // popover stays glued just above the button.
      bottom: viewportHeight - rect.top + gap,
      left,
      maxHeight: Math.max(0, spaceAbove),
    };
  }
  return {
    top: rect.bottom + gap,
    bottom: "auto",
    left,
    maxHeight: Math.max(0, spaceBelow),
  };
}
