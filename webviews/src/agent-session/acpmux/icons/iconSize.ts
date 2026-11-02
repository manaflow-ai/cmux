/// The icon scale (leo-workspace design/grid.md, "Icon sizes"): 12 for status marks, chevrons,
/// spinners and close marks; 14 for menu rows and marks inline with text; 16 for buttons and
/// compact rows; 20 for primary rows. Artwork (avatars, empty states) is 24 or larger. The
/// composer's own glyph set draws at 18 (ComposerPickers.tsx). No icon draws smaller than this.
export const ICON_FLOOR = 12;

/// A row icon crops the grid's 2.5-unit margin so its strokes line up with the label's cap height;
/// the svg keeps overflow visible so nothing is clipped.
export const ROW_VIEWBOX = "2.5 2.5 19 19";

/// The icon size for a row whose label is `labelPx` pixels.
export function rowIconSize(labelPx: number): number {
  return Math.max(ICON_FLOOR, Math.round(1.2 * labelPx));
}
