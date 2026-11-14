// The mock app's chrome fills (the window, its sidebar, the pane strips) and the colours they paint over the
// regions schemas/theme/chrome-layer-colors.json records from the native window (ChromeLayerColorTests): the
// sidebar list, its footer and the titlebar row over the main column. main.ts paints the fills;
// test/chrome-layer-colors.test.ts holds the regions to the file, so the gallery's window and the app's stay one
// colour (Leo, 2026-11-11, after #39984 dimmed the sidebar: "bro why is the sidebar now a different color?").
import { composited, withAlpha, wallpaperTintOpacity, type ThemeRGB, type ThemeTokens } from "../theme/tokens";

export type ChromeFills = {
  /** The window's sheet: the surface, or over a picture the theme tint at its wallpaper opacity. */
  window: ThemeRGB;
  /** The sidebar's own fill over the window; null when it paints none (over a picture). */
  sidebar: ThemeRGB | null;
  /** Each pane's tab strip over the window; null when it paints none (over a picture). */
  strip: ThemeRGB | null;
};

export function chromeFills(tokens: ThemeTokens, overPicture: boolean): ChromeFills {
  if (overPicture)
    return {
      window: withAlpha(tokens.windowBackground, wallpaperTintOpacity(tokens)),
      sidebar: null,
      strip: null,
    };
  return { window: tokens.windowBackground, sidebar: tokens.sidebarBackground, strip: tokens.stripBackground };
}

/** What ChromeLayerColorTests counts a background picture as: one mid grey, the same on every machine. */
export const PICTURE_STAND_IN: ThemeRGB = { red: 0.5, green: 0.5, blue: 0.5, alpha: 1 };

export type ChromeRegion = "sidebar" | "footer" | "titlebar";

/** The colour each recorded region shows: the fills over it, in drawing order, over the opaque surface (or over
 * the picture's stand-in). */
export function chromeRegions(tokens: ThemeTokens, overPicture: boolean): Record<ChromeRegion, ThemeRGB> {
  const fills = chromeFills(tokens, overPicture);
  const base = overPicture ? PICTURE_STAND_IN : withAlpha(tokens.surfaceBackground, 1);
  const window = composited(fills.window, base);
  const sidebar = fills.sidebar ? composited(fills.sidebar, window) : window;
  return { sidebar, footer: sidebar, titlebar: window };
}

/** `#RRGGBB`, each channel rounded half away from zero (ChromeLayerHex in the Swift suite). */
export function chromeHex(color: ThemeRGB): string {
  const channel = (value: number) =>
    Math.round(Math.min(Math.max(value, 0), 1) * 255)
      .toString(16)
      .toUpperCase()
      .padStart(2, "0");
  return `#${channel(color.red)}${channel(color.green)}${channel(color.blue)}`;
}
