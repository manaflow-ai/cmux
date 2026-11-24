import { HOVER_INTENT } from "../../../ui/hoverIntent";

/// The preview's width, its gap under the icon and its least room from the window's right edge, at
/// the default Text Size, CSS px.
const PREVIEW_WIDTH = 176;
export const PREVIEW_GAP = 6;
const PREVIEW_EDGE = 8;

/** How long the pointer rests on an icon before its preview shows: a tooltip-sized label, so the
 * tooltip delay (`HOVER_INTENT.tooltipDelay`); hover cards wait `HOVER_INTENT.cardDwell`. */
export const PREVIEW_INTENT_DELAY: number = HOVER_INTENT.tooltipDelay;

/** The preview's width and its `right` (CSS px from the window's right edge) under a button whose
 * box ends at `boxRight`, at Text Size `scale`. Its right edge lines up with the button's, and it
 * stays `PREVIEW_EDGE` inside the window on both sides: grown with Text Size under a left-side
 * icon, it would otherwise run past the window's left edge. */
export function headerToolPreviewPlacement(
  viewport: number,
  boxRight: number,
  scale: number,
): { width: number; right: number } {
  const edge = PREVIEW_EDGE * scale;
  const width = Math.min(PREVIEW_WIDTH * scale, Math.max(0, viewport - 2 * edge));
  const right = Math.min(Math.max(edge, viewport - boxRight), Math.max(edge, viewport - width - edge));
  return { width, right };
}
