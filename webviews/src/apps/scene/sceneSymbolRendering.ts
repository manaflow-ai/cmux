import { sceneColor } from "./sceneStyle";

/** `Icon`'s `symbolRendering`: how a glyph's layers take color (SF Symbols' rendering modes). */
export type SymbolRendering = "monochrome" | "hierarchical" | "palette" | "multicolor";

const YELLOW = "#FFCC00"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const BLUE = "#0A84FF"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const ORANGE = "#FF9F0A"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const RED = "#FF453A"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour
const CYAN = "#64D2FF"; // colour-allow: SF Symbols' fixed multicolor value (AppKit draws the same), not a theme colour

/** SF Symbols' own multicolor, per draw layer in the symbol's order (null keeps the tint). A glyph
 * colored as a whole takes the entry only when it has one color (a sun is yellow either way); a
 * layered entry, or a symbol not listed, draws in the tint. */
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

/** The one color `symbol` (its SF name) takes in `rendering`, for the whole glyph, or undefined to keep
 * the tint. Palette draws in its first color; multicolor takes a one-color entry (a sun is yellow).
 * Hierarchical, monochrome, an unknown mode and a layered multicolor entry keep the tint: the scene
 * colors a glyph as a whole, while AppKit draws every mode layer by layer. */
export function symbolGlyphColor(symbol: string, rendering: unknown, palette: unknown): string | undefined {
  switch (sceneSymbolRendering(rendering)) {
    case "palette":
      return scenePalette(palette)?.[0];
    case "multicolor": {
      const entry = MULTICOLOR[symbol];
      return entry?.length === 1 && entry[0] ? entry[0] : undefined;
    }
    default:
      return undefined;
  }
}
