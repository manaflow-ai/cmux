// A static status glyph (Leo 2026-10-14, the Static status mode): one still shape per state, told apart
// by shape alone, tinted by its theme role. The paths are generated with the app's
// (statusGlyphs.generated.ts from schemas/status-glyphs/static-status.json).
import { STATUS_GLYPHS, type StatusGlyphName } from "./statusGlyphs.generated";

/** Whether a glyph `size` px wide takes the 1x pixel art at the window's pixel ratio: the same rule as
 * the app's `StaticStatusGlyph.usesHinting`: exactly 10 device pixels. Larger squares (3x, 5x) draw
 * the master's curves; the art blown up would draw in coarse blocks. */
export function usesPixelArt(size: number, pixelRatio: number): boolean {
  const pixels = size * pixelRatio;
  return pixels === 10;
}

export function StatusGlyph({
  name,
  size = 10,
  label,
  className,
  tint,
}: {
  name: StatusGlyphName;
  /** The color, when a set tints the glyph otherwise (`STATUS_GLYPH_SETS`); else the glyph's own. */
  tint?: string;
  /** Width and height in px (10 is the status slot). */
  size?: number;
  /** What it says to assistive tech; absent, the glyph is hidden from it (its row says the state). */
  label?: string;
  className?: string;
}) {
  const art = STATUS_GLYPHS[name];
  const color = tint ?? art.tint;
  const pixelArt = usesPixelArt(size, typeof window === "undefined" ? 2 : window.devicePixelRatio);
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox={pixelArt ? "0 0 10 10" : "0 0 20 20"}
      fill="currentColor"
      style={{ color, flexShrink: 0 }}
      shapeRendering={pixelArt ? "crispEdges" : "geometricPrecision"}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : "true"}
      data-status-glyph={name}
      data-tint={color}
    >
      <path d={pixelArt ? art.x1 : art.master} fillRule="evenodd" />
    </svg>
  );
}
