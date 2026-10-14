// A static status glyph (Leo 2026-10-14, the Static status mode): one still shape per state, told apart
// by shape alone, tinted by its theme role. The paths are generated with the app's
// (statusGlyphs.generated.ts from schemas/status-glyphs/static-status.json).
import {
  DEFAULT_STATUS_GLYPH_SET,
  STATUS_GLYPH_SETS,
  type StatusGlyphName,
  type StatusGlyphSetName,
} from "./statusGlyphs.generated";

/** Whether a glyph `size` px wide takes the 1x pixel art at the window's pixel ratio: the same rule as
 * the app's `StaticStatusGlyph.usesHinting` (10 device pixels, or an odd multiple of 10). */
export function usesPixelArt(size: number, pixelRatio: number): boolean {
  const pixels = size * pixelRatio;
  return Number.isInteger(pixels) && pixels % 20 === 10;
}

export function StatusGlyph({
  name,
  set = DEFAULT_STATUS_GLYPH_SET,
  size = 10,
  label,
  className,
}: {
  name: StatusGlyphName;
  /** Which set draws it (hq#1957 status glyph thunderdome); the default set when absent. */
  set?: StatusGlyphSetName;
  /** Width and height in px (10 is the status slot). */
  size?: number;
  /** What it says to assistive tech; absent, the glyph is hidden from it (its row says the state). */
  label?: string;
  className?: string;
}) {
  const art = STATUS_GLYPH_SETS[set].glyphs[name];
  const pixelArt = usesPixelArt(size, typeof window === "undefined" ? 2 : window.devicePixelRatio);
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox={pixelArt ? "0 0 10 10" : "0 0 20 20"}
      fill="currentColor"
      style={{ color: art.tint, flexShrink: 0 }}
      shapeRendering={pixelArt ? "crispEdges" : "geometricPrecision"}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : "true"}
      data-status-glyph={name}
      data-status-glyph-set={set}
      data-tint={art.tint}
    >
      <path d={pixelArt ? art.x1 : art.master} fillRule="evenodd" />
    </svg>
  );
}
