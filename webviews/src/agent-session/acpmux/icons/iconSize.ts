/// No icon draws smaller than this many pixels.
export const ICON_FLOOR = 12;

/// A row icon crops the grid's 2.5-unit margin so its strokes line up with the label's cap height;
/// the svg keeps overflow visible so nothing is clipped.
export const ROW_VIEWBOX = "2.5 2.5 19 19";

/// The icon size for a row whose label is `labelPx` pixels.
export function rowIconSize(labelPx: number): number {
  return Math.max(ICON_FLOOR, Math.round(1.2 * labelPx));
}
