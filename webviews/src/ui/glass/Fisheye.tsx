// The fisheye lens (glass.css "FISHEYE"): a small round glass that magnifies and bends the page
// under it, as Apple's liquid glass lens does (Leo, 2026-10-21, on Jump to latest: "I want, like
// glassier stuff. I want it to be like a fucking glass, like a lens thing, like a fisheye. I want
// more fisheye!"). Chromium runs an SVG filter as a backdrop filter, so the disc draws the page's
// own pixels (the transcript text) through a barrel displacement: the middle zooms in, the rim
// squeezes, and nothing past the rim is sampled. WebKit draws nothing for an SVG backdrop filter, so
// there the disc stays the shared glass (glass.css keeps the rule Chromium-only). Reduce
// Transparency keeps the opaque surface.
//
// Cost: no script runs per frame. The map is drawn once per document (a 64 px canvas, memoized) and
// Chromium re-runs the filter for this one 32 px disc only while its backdrop moves; no rows are
// read or walked.
import { memo } from "react";

/** The lens strengths: how far the middle zooms in, as `k` in r' = r (1 - k (1 - r²)) (the page
 * point a disc point at radius r shows, both in disc radii). The middle's zoom is 1 / (1 - k). */
export const FISHEYE_STRENGTHS = {
  /** 1.4x in the middle. */
  soft: 0.3,
  /** 1.8x in the middle: the shipped strength (the most fisheye one whose glyph and the words
   * under it still read at 32 px). */
  medium: 0.45,
  /** 2.5x in the middle: a letter or two fills the disc. */
  strong: 0.6,
} as const;
export type FisheyeStrength = keyof typeof FISHEYE_STRENGTHS;
export const FISHEYE_DEFAULT: FisheyeStrength = "medium";

/** The filter id glass.css names for `strength` (`--glass-fisheye`). */
export function fisheyeFilterId(strength: FisheyeStrength): string {
  return `cmux-glass-fisheye-${strength}`;
}

const MAP_SIZE = 64;
/** The most a disc point moves, in disc radii, before `k`: max of r (1 - r²) is 2 / (3 √3). */
const MAP_REACH = 0.4;

let cachedMap: string | undefined;
/** The displacement map, a data URL: red and green hold the inward pull at each disc point
 * (128 is none), zero at the middle and at the rim, and none outside the circle. */
export function fisheyeMap(doc: Document = document): string {
  if (cachedMap !== undefined) return cachedMap;
  const canvas = doc.createElement("canvas");
  canvas.width = MAP_SIZE;
  canvas.height = MAP_SIZE;
  const context = canvas.getContext("2d");
  if (!context) return "";
  const image = context.createImageData(MAP_SIZE, MAP_SIZE);
  for (let y = 0; y < MAP_SIZE; y++) {
    for (let x = 0; x < MAP_SIZE; x++) {
      const u = ((x + 0.5) / MAP_SIZE) * 2 - 1;
      const v = ((y + 0.5) / MAP_SIZE) * 2 - 1;
      const r2 = u * u + v * v;
      // feDisplacementMap samples at P + scale (C - 0.5). The disc point P shows the page point
      // P (1 - k (1 - r²)), so the pull is -P (1 - r²), scaled by k in the filter's `scale`.
      const pull = r2 < 1 ? 1 - r2 : 0;
      const at = (y * MAP_SIZE + x) * 4;
      image.data[at] = Math.round(128 - (127 * u * pull) / MAP_REACH);
      image.data[at + 1] = Math.round(128 - (127 * v * pull) / MAP_REACH);
      image.data[at + 2] = 128;
      image.data[at + 3] = 255;
    }
  }
  context.putImageData(image, 0, 0);
  cachedMap = canvas.toDataURL("image/png");
  return cachedMap;
}

/** The filters for a `size` px disc, one per strength (only the one glass.css names runs). Each
 * bends the backdrop, then lays it over the theme surface: Chromium draws a backdrop copy over the
 * page's own pixels, so a see-through page's text would show twice through a clear copy. */
export const FisheyeFilters = memo(function FisheyeFilters({ size }: { size: number }) {
  const href = typeof document === "undefined" ? "" : fisheyeMap();
  if (!href) return null;
  return (
    <svg
      aria-hidden="true"
      width="0"
      height="0"
      focusable="false"
      style={{ position: "absolute", width: 0, height: 0, overflow: "hidden", pointerEvents: "none" }}
    >
      {(Object.keys(FISHEYE_STRENGTHS) as FisheyeStrength[]).map((strength) => (
        <filter
          key={strength}
          id={fisheyeFilterId(strength)}
          x="0"
          y="0"
          width={size}
          height={size}
          filterUnits="userSpaceOnUse"
          primitiveUnits="userSpaceOnUse"
          colorInterpolationFilters="sRGB"
        >
          <feImage href={href} x="0" y="0" width={size} height={size} preserveAspectRatio="none" result="map" />
          <feDisplacementMap
            in="SourceGraphic"
            in2="map"
            // A pull of 1 is one disc radius (size / 2) at k = 1 (fisheyeMap's MAP_REACH).
            scale={2 * MAP_REACH * (size / 2) * FISHEYE_STRENGTHS[strength]}
            xChannelSelector="R"
            yChannelSelector="G"
            result="moved"
          />
          {/* feDisplacementMap takes the nearest source pixel, which leaves text under the bend
              jagged; a quarter-pixel blur smooths it without frosting the words. */}
          <feGaussianBlur in="moved" stdDeviation="0.35" result="bent" />
          <feFlood style={{ floodColor: "var(--glass-surface)" }} result="surface" />
          <feMerge>
            <feMergeNode in="surface" />
            <feMergeNode in="bent" />
          </feMerge>
        </filter>
      ))}
    </svg>
  );
});
