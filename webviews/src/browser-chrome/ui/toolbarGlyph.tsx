// One glyph family for the browser toolbar row: Back, Forward, Reload, the omnibar's chip icon and
// star, the Extensions puzzle, the trailing buttons and More all draw at one ink size and one line
// weight, centered on their box. The Chromium drawings come on different canvases (the arrows span
// 12 of Chrome's 20 dp, the puzzle 16 and a pixel high, the star 16 by 15), so drawn at one `size`
// they read as three sizes and two center lines. Here each glyph's own ink box is measured, scaled
// so its longer side is `ink` px, and its outline thickened (a stroke on the filled shape) until its
// lines are `weight` px. A glyph that would need thinning instead (the Stop cross, the small Downloads
// square inside its ring) keeps the weight and draws smaller, as those two are drawn to.
import { useId } from "react";
import { MISSING_ICON, resolveIcon } from "../../agent-session/acpmux/icons/iconPack";
import { iconLayers } from "../../agent-session/acpmux/icons/iconLayers";
import { useIcons } from "../../agent-session/acpmux/icons/IconsContext";
import { inkBounds } from "../../agent-session/acpmux/icons/opticalFit";
import type { IconLayer } from "../../agent-session/acpmux/icons/types";

/** The ink size and line weight every glyph in the row draws at, in px. */
export type GlyphScale = { ink: number; weight: number };

/**
 * The line weight of a filled Chromium drawing in pack units: Chrome draws its toolbar set with
 * 1.5 dp lines on a 20 dp canvas, which the pack scales by 1.2 to its 24-unit grid.
 */
export const FILLED_LINE_WEIGHT = 1.8;

/**
 * Optical corrections (the icon spec's coverage trim): shapes that fill most of their box read
 * larger than open ones at the same extent (the puzzle's square body, the crashed-extension disc,
 * the side panel), and a star's thin points read smaller.
 */
export const OPTICAL_TRIM: Readonly<Record<string, number>> = {
  "browser.toolbar.extensions": 0.94,
  "browser.toolbar.extensions.crashed": 0.94,
  "browser.toolbar.bookmarks": 0.94,
  "browser.omnibox.star": 1.06,
  "browser.omnibox.star.active": 1.06,
};

/**
 * The row's glyph rule (the gallery compares them):
 * - `family`: every glyph, buttons and the omnibar's chip and star, at 5/8 of the toolbar icon size
 *   (12.5 px at Standard) with lines of 1/16 of it (1.5625 px): the app's own icons at 20 px.
 * - `text`: the buttons as `family`, the omnibar's chip and star a step smaller (11.5 px at 1.5 px).
 * - `bold`: every glyph at 0.7 of the icon size (14 px) with 1.75 px lines.
 */
export type GlyphLook = "family" | "text" | "bold";

/** The scales for the buttons and for the omnibar's own glyphs, and the profile badge's diameter. */
export type GlyphRule = { button: GlyphScale; omnibar: GlyphScale; badge: number };

/** The rule at a density: the host's toolbar icon size (20 at Standard) sets every number. */
export function glyphRule(toolbarIcon: number, look: GlyphLook = "family"): GlyphRule {
  const unit = toolbarIcon / 20;
  const family = { ink: 12.5 * unit, weight: 1.5625 * unit };
  switch (look) {
    case "family":
      return { button: family, omnibar: family, badge: 15 * unit };
    case "text":
      return { button: family, omnibar: { ink: 11.5 * unit, weight: 1.5 * unit }, badge: 15 * unit };
    case "bold":
      return {
        button: { ink: 14 * unit, weight: 1.75 * unit },
        omnibar: { ink: 14 * unit, weight: 1.75 * unit },
        badge: 17 * unit,
      };
  }
}

export type GlyphFit = {
  /** The svg's viewBox: `box` px wide, centered on the glyph's ink. */
  viewBox: string;
  /** The drawn layers, stroke widths set to the row's weight. */
  layers: IconLayer[];
  /** The outline added to filled layers, in viewBox units (0: none). */
  outline: number;
};

const round = (value: number) => Math.round(value * 1000) / 1000;

/** Fits `layers` (on the 24-unit grid) into a `box` px square at `scale`; `trim` shrinks dense shapes. */
export function fitGlyph(layers: readonly IconLayer[], scale: GlyphScale, box: number, trim = 1): GlyphFit {
  const ink = inkBounds(layers);
  if (!ink) return { viewBox: "0 0 24 24", layers: [...layers], outline: 0 };
  const longest = Math.max(ink.x1 - ink.x0, ink.y1 - ink.y0);
  const target = scale.ink * trim;
  const stroked = ink.stroke > 0;
  // An outline would also widen an erasing layer's mask, so a drawing with one is only scaled.
  const erases = layers.some((layer) => layer.op === "clearFill" || layer.op === "clearStroke");
  let pxPerUnit: number;
  let outlinePx = 0;
  if (stroked) {
    // A line drawing: the geometry spans the target less one line, every line at the weight.
    pxPerUnit = longest > 0 ? (target - scale.weight) / longest : 1;
  } else {
    // A filled drawing whose lines are FILLED_LINE_WEIGHT units: scale, then thicken to the weight.
    const span = longest - FILLED_LINE_WEIGHT;
    pxPerUnit = Math.min(span > 0 ? (target - scale.weight) / span : 1, scale.weight / FILLED_LINE_WEIGHT);
    if (!erases) outlinePx = Math.max(0, scale.weight - FILLED_LINE_WEIGHT * pxPerUnit);
  }
  const units = box / pxPerUnit;
  const cx = (ink.x0 + ink.x1) / 2;
  const cy = (ink.y0 + ink.y1) / 2;
  const lineUnits = round(scale.weight / pxPerUnit);
  return {
    viewBox: [cx - units / 2, cy - units / 2, units, units].map(round).join(" "),
    layers: stroked
      ? layers.map((layer) =>
          layer.op === "stroke" || layer.op === "clearStroke"
            ? { ...layer, w: round(((layer.w ?? 1.5) * lineUnits) / ink.stroke) }
            : layer,
        )
      : [...layers],
    outline: round(outlinePx / pxPerUnit),
  };
}

const fits = new WeakMap<readonly IconLayer[], Map<string, GlyphFit>>();

function cachedFit(layers: IconLayer[], scale: GlyphScale, box: number, trim: number): GlyphFit {
  let byScale = fits.get(layers);
  if (!byScale) {
    byScale = new Map();
    fits.set(layers, byScale);
  }
  const key = `${scale.ink}/${scale.weight}/${box}/${trim}`;
  let fit = byScale.get(key);
  if (!fit) {
    fit = fitGlyph(layers, scale, box, trim);
    byScale.set(key, fit);
  }
  return fit;
}

/** A toolbar glyph from the active pack, `box` px square, its ink centered at `scale`. */
export function ToolbarGlyph({ name, scale, box }: { name: string; scale: GlyphScale; box: number }) {
  const { pack, accent } = useIcons();
  const id = useId().replace(/[^\w-]/g, "");
  const layers = resolveIcon(pack, name, "line", accent) ?? resolveIcon(pack, MISSING_ICON, "line", accent);
  if (!layers) return null;
  const fit = cachedFit(layers, scale, box, OPTICAL_TRIM[name] ?? 1);
  return (
    <svg
      className="bc-glyph"
      viewBox={fit.viewBox}
      width={box}
      height={box}
      overflow="visible"
      data-icon={name}
      aria-hidden="true"
      focusable="false"
      stroke={fit.outline > 0 ? "currentColor" : undefined}
      strokeWidth={fit.outline > 0 ? fit.outline : undefined}
      strokeLinejoin={fit.outline > 0 ? "round" : undefined}
    >
      {iconLayers(fit.layers, `bc-glyph-${id}`)}
    </svg>
  );
}
