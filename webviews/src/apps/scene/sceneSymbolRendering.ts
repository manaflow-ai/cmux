import { sceneColor } from "./sceneStyle";

/** `Icon`'s `symbolRendering`: how a glyph's layers take color (SF Symbols' rendering modes). */
export type SymbolRendering = "monochrome" | "hierarchical" | "palette" | "multicolor";

const YELLOW = "#FFCC00"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const BLUE = "#0A84FF"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const ORANGE = "#FF9F0A"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const RED = "#FF453A"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const CYAN = "#64D2FF"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour

/** SF Symbols' own multicolor, per draw layer in the symbol's order (null keeps the tint). A glyph
 * with one layer takes the entry only when the entry has one color (a sun is yellow either way);
 * a layered entry on a one-layer glyph, or a symbol not listed, draws in the tint. */
const MULTICOLOR: Record<string, readonly (string | null)[]> = {
  "sun.max": [YELLOW],
  "sun.max.fill": [YELLOW],
  "sun.min": [YELLOW],
  "sun.min.fill": [YELLOW],
  sunrise: [null, YELLOW],
  "sunrise.fill": [null, YELLOW],
  sunset: [null, YELLOW],
  "sunset.fill": [null, YELLOW],
  "cloud.sun": [null, YELLOW],
  "cloud.sun.fill": [null, YELLOW],
  "cloud.sun.rain": [null, YELLOW, BLUE],
  "cloud.sun.rain.fill": [null, YELLOW, BLUE],
  "cloud.sun.bolt": [null, YELLOW, YELLOW],
  "cloud.sun.bolt.fill": [null, YELLOW, YELLOW],
  "cloud.rain": [null, BLUE],
  "cloud.rain.fill": [null, BLUE],
  "cloud.drizzle": [null, BLUE],
  "cloud.drizzle.fill": [null, BLUE],
  "cloud.heavyrain": [null, BLUE],
  "cloud.heavyrain.fill": [null, BLUE],
  "cloud.bolt": [null, YELLOW],
  "cloud.bolt.fill": [null, YELLOW],
  "cloud.bolt.rain": [null, YELLOW, BLUE],
  "cloud.bolt.rain.fill": [null, YELLOW, BLUE],
  "cloud.hail": [null, CYAN],
  "cloud.hail.fill": [null, CYAN],
  "cloud.sleet": [null, CYAN],
  "cloud.sleet.fill": [null, CYAN],
  "cloud.snow": [null, CYAN],
  "cloud.snow.fill": [null, CYAN],
  "cloud.moon.rain": [null, null, BLUE],
  "cloud.moon.rain.fill": [null, null, BLUE],
  "moon.stars": [null, YELLOW],
  "moon.stars.fill": [null, YELLOW],
  "thermometer.sun": [null, YELLOW],
  "thermometer.sun.fill": [null, YELLOW],
  umbrella: [BLUE],
  "umbrella.fill": [BLUE],
  drop: [BLUE],
  "drop.fill": [BLUE],
  bolt: [YELLOW],
  "bolt.fill": [YELLOW],
  flame: [ORANGE],
  "flame.fill": [ORANGE],
  "heart.fill": [RED],
  "exclamationmark.triangle.fill": [YELLOW],
};

/** Hierarchical's opacities by layer (primary, secondary, tertiary), as SF Symbols draw them. */
const HIERARCHY = [1, 0.5, 0.25] as const;

const MODES: readonly string[] = ["monochrome", "hierarchical", "palette", "multicolor"];

/** A valid `symbolRendering` value, or undefined (monochrome). */
export function sceneSymbolRendering(value: unknown): SymbolRendering | undefined {
  return typeof value === "string" && MODES.includes(value) ? (value as SymbolRendering) : undefined;
}

/** `symbolColors`: 1 to 3 tokens or hex, all valid, else undefined. */
export function scenePalette(value: unknown): string[] | undefined {
  if (!Array.isArray(value) || value.length < 1 || value.length > 3) return undefined;
  const colors = value.map(sceneColor);
  return colors.every((color): color is string => color !== undefined) ? colors : undefined;
}

/** The per-layer paint of `symbol` (its SF name) in `rendering`, for `Icon`'s `layerPaint`, or undefined
 * when every layer keeps the tint (monochrome, an unknown mode, a symbol with no multicolor entry). */
export function symbolLayerPaint(
  symbol: string,
  rendering: unknown,
  palette: unknown,
): ((index: number, count: number) => { color?: string; opacity?: number } | undefined) | undefined {
  switch (sceneSymbolRendering(rendering)) {
    case "hierarchical":
      return (index, count) => (count > 1 ? { opacity: HIERARCHY[Math.min(index, HIERARCHY.length - 1)] } : undefined);
    case "palette": {
      const colors = scenePalette(palette);
      return colors ? (index) => ({ color: colors[Math.min(index, colors.length - 1)] }) : undefined;
    }
    case "multicolor": {
      const entry = MULTICOLOR[symbol];
      if (!entry) return undefined;
      return (index, count) => {
        // A one-layer glyph takes a one-color entry (a sun) and keeps the tint for a layered one.
        if (count === 1) return entry.length === 1 && entry[0] ? { color: entry[0] } : undefined;
        const color = entry[Math.min(index, entry.length - 1)];
        return color ? { color } : undefined;
      };
    }
    default:
      return undefined;
  }
}
