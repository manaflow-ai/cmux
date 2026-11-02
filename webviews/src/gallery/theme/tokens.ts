// The app's chrome tokens, derived from a Ghostty theme exactly as the Swift side derives them:
// a line-for-line port of Packages/Shared/CmuxTheme (ThemeRGB.swift, ThemeInput.swift,
// ThemeTokens.swift). The gallery paints every web page with these, so a theme here looks as it
// does in the app.
import { deriveAppTheme, type AppAccent } from "../../theme/appTheme";

export type ThemeRGB = { red: number; green: number; blue: number; alpha: number };

const clamp = (value: number) => Math.min(Math.max(value, 0), 1);

export function rgb(red: number, green: number, blue: number, alpha = 1): ThemeRGB {
  return { red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha) };
}

export function rgbHex(hex: number, alpha = 1): ThemeRGB {
  return rgb(((hex >> 16) & 0xff) / 255, ((hex >> 8) & 0xff) / 255, (hex & 0xff) / 255, alpha);
}

/** `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` optional), as Ghostty and cmux.json write colors. */
export function parseHex(text: string): ThemeRGB | null {
  let digits = text.trim();
  if (digits.startsWith("#")) digits = digits.slice(1);
  if (![3, 6, 8].includes(digits.length) || !/^[0-9a-fA-F]+$/.test(digits)) return null;
  if (digits.length === 3)
    digits = digits
      .split("")
      .map((digit) => digit + digit)
      .join("");
  const alpha = digits.length === 8 ? parseInt(digits.slice(6), 16) / 255 : 1;
  return rgbHex(parseInt(digits.slice(0, 6), 16), alpha);
}

export const BLACK = rgb(0, 0, 0);
export const WHITE = rgb(1, 1, 1);

export function luminance(color: ThemeRGB): number {
  const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue);
}

export function contrast(a: ThemeRGB, b: ThemeRGB): number {
  const x = luminance(a);
  const y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

export function mixed(color: ThemeRGB, other: ThemeRGB, fraction: number): ThemeRGB {
  const t = clamp(fraction);
  return rgb(
    color.red + (other.red - color.red) * t,
    color.green + (other.green - color.green) * t,
    color.blue + (other.blue - color.blue) * t,
    color.alpha,
  );
}

export const withAlpha = (color: ThemeRGB, alpha: number) => rgb(color.red, color.green, color.blue, alpha);

export function composited(color: ThemeRGB, base: ThemeRGB): ThemeRGB {
  return withAlpha(mixed(base, withAlpha(color, 1), color.alpha), 1);
}

/** The terminal theme's colors (ThemeInput.swift). */
export type ThemeInput = {
  background: ThemeRGB;
  foreground: ThemeRGB;
  palette: ThemeRGB[];
  selectionBackground?: ThemeRGB;
  selectionForeground?: ThemeRGB;
  backgroundOpacity: number;
  /** `appearance.accent` (ThemeInput.accent); neutral when absent. */
  accent?: AppAccent;
  /** The theme's own accent (ThemeInput.accentColor); wins over `accent`. */
  accentColor?: ThemeRGB | null;
};

export const GHOSTTY_DEFAULT: ThemeInput = {
  background: rgbHex(0x282c34),
  foreground: rgbHex(0xffffff),
  palette: [
    0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6, 0x666666, 0xd54e53, 0xb9ca4a,
    0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
  ].map((hex) => rgbHex(hex)),
  backgroundOpacity: 1,
};

export const MINIMUM_TEXT_CONTRAST = 4.5;
export const MINIMUM_MARK_CONTRAST = 3;

export type ThemeTokens = {
  isDark: boolean;
  windowBackground: ThemeRGB;
  sidebarBackground: ThemeRGB;
  contentBackground: ThemeRGB;
  surfaceBackground: ThemeRGB;
  chromeBackground: ThemeRGB;
  elevatedBackground: ThemeRGB;
  stripBackground: ThemeRGB;
  sidebarStep: ThemeRGB;
  textPrimary: ThemeRGB;
  textSecondary: ThemeRGB;
  textTertiary: ThemeRGB;
  hoverFill: ThemeRGB;
  selectionFill: ThemeRGB;
  secondarySelectionFill: ThemeRGB;
  pressedFill: ThemeRGB;
  badgeFill: ThemeRGB;
  separator: ThemeRGB;
  paneBorder: ThemeRGB;
  focusRing: ThemeRGB;
  glassTint: ThemeRGB;
  shadow: ThemeRGB;
  textSelection: ThemeRGB;
  attention: ThemeRGB;
  danger: ThemeRGB;
  success: ThemeRGB;
  highlight: ThemeRGB;
  highlightText: ThemeRGB;
  accent: ThemeRGB;
  onAccent: ThemeRGB;
  hasThemeAccent: boolean;
  ansi: ThemeRGB[];
  backgroundOpacity: number;
};

/** `color`, pushed toward white or black until it reaches `minimum` contrast over `surface`. */
export function readable(color: ThemeRGB, surface: ThemeRGB, minimum: number): ThemeRGB {
  if (contrast(color, surface) >= minimum) return color;
  const pole = luminance(surface) < 0.18 ? WHITE : BLACK;
  let step = 0;
  let candidate = color;
  while (step < 1 && contrast(candidate, surface) < minimum) {
    step += 0.02;
    candidate = mixed(color, pole, step);
  }
  return candidate;
}

/** `color` walked toward `pole` until it reaches `minimum` contrast over every surface (or `pole`). */
function readableOver(color: ThemeRGB, surfaces: ThemeRGB[], pole: ThemeRGB, minimum: number): ThemeRGB {
  const reads = (ink: ThemeRGB) => surfaces.every((surface) => contrast(ink, surface) >= minimum);
  let step = 0;
  let candidate = color;
  while (step < 1 && !reads(candidate)) {
    step += 0.02;
    candidate = mixed(color, pole, step);
  }
  return candidate;
}

/**
 * What text sits on in a window of `opacity` below 1 (ThemeTokens.seeThroughSurfaces): the background
 * at that opacity over the worst desktop for the theme, alone and under each of `fills`.
 */
function seeThroughSurfaces(bg: ThemeRGB, opacity: number, isDark: boolean, fills: ThemeRGB[]): ThemeRGB[] {
  if (opacity >= 1) return [];
  const tint = composited(withAlpha(bg, opacity), isDark ? WHITE : BLACK);
  return [tint, ...fills.map((fill) => composited(fill, tint))];
}

/**
 * ThemeTokens.inks: the primary, secondary and tertiary text for `foreground`, read on every surface in
 * `rows` (the strongest row fill and the bare background). A foreground that reads keeps its color;
 * otherwise it is walked toward white and toward black (the pole that reads better on the row fill
 * first), and the candidate whose primary and secondary keep the higher least contrast over `rows`
 * wins, capped at 4.5:1 (a tie keeps the first). Hot Dog Stand takes the dark ink, Grass white.
 */
export function inks(
  foreground: ThemeRGB,
  rows: ThemeRGB[],
  seeThrough: ThemeRGB[],
  bg: ThemeRGB,
): [ThemeRGB, ThemeRGB, ThemeRGB] {
  const least = (ink: ThemeRGB) => Math.min(...rows.map((row) => contrast(ink, row)));
  const poles = contrast(BLACK, rows[0]!) > contrast(WHITE, rows[0]!) ? [BLACK, WHITE] : [WHITE, BLACK];
  let chosen: { score: number; inks: [ThemeRGB, ThemeRGB, ThemeRGB] } | null = null;
  for (const pole of poles) {
    const primary = readableOver(foreground, rows, pole, MINIMUM_TEXT_CONTRAST);
    // Swift's `min` keeps the first of equal elements; so does this reduce.
    const inkSurface = [...rows, ...seeThrough].reduce((worst, next) =>
      contrast(primary, next) < contrast(primary, worst) ? next : worst,
    );
    const secondary = muted(primary, bg, 0.38, inkSurface, MINIMUM_TEXT_CONTRAST);
    const tertiary = muted(primary, bg, 0.55, inkSurface, MINIMUM_MARK_CONTRAST);
    const score = Math.min(least(primary), least(secondary), MINIMUM_TEXT_CONTRAST);
    if (!chosen || score > chosen.score) chosen = { score, inks: [primary, secondary, tertiary] };
  }
  return chosen!.inks;
}

function muted(color: ThemeRGB, target: ThemeRGB, limit: number, surface: ThemeRGB, minimum: number): ThemeRGB {
  let fraction = limit;
  while (fraction > 0) {
    const candidate = mixed(color, target, fraction);
    if (contrast(candidate, surface) >= minimum) return candidate;
    fraction -= 0.01;
  }
  return color;
}

/** ThemeTokens.derive(from:). */
export function deriveTokens(input: ThemeInput): ThemeTokens {
  const bg = input.background;
  const fg = input.foreground;
  const isDark = luminance(bg) < luminance(fg);
  // The app theme when the setting or the theme names an accent; null keeps the neutral fills.
  const app =
    (input.accent && input.accent !== "neutral") || input.accentColor
      ? deriveAppTheme(
          {
            background: hex(bg),
            foreground: hex(fg),
            palette: input.palette.map(hex),
            accent: input.accentColor ? hex(input.accentColor) : null,
          },
          input.accent ?? "neutral",
        )
      : null;
  const accent = app ? parseHex(app.tokens.accent) : null;
  const hover = withAlpha(fg, isDark ? 0.06 : 0.05);
  const selection = accent ? withAlpha(accent, isDark ? 0.26 : 0.16) : withAlpha(fg, isDark ? 0.1 : 0.08);
  const pressed = withAlpha(fg, isDark ? 0.14 : 0.11);
  // Swift's `min` keeps the first of equal elements; so does this reduce.
  const worstSurface = [composited(pressed, bg), composited(selection, bg)].reduce((worst, next) =>
    contrast(fg, next) < contrast(fg, worst) ? next : worst,
  );
  // In a see-through window the quieter inks also hold over the tint on the worst desktop.
  const seeThrough = seeThroughSurfaces(bg, input.backgroundOpacity, isDark, [pressed, selection]);
  const [primary, secondary, tertiary] = inks(fg, [worstSurface, bg], seeThrough, bg);
  const palette = input.palette.length >= 8 ? input.palette : GHOSTTY_DEFAULT.palette;
  const status = (index: number) => readable(palette[index]!, bg, MINIMUM_MARK_CONTRAST);
  const surface = withAlpha(bg, input.backgroundOpacity);
  const highlight = accent ?? status(4);
  // Swift's `max` keeps the last of equal elements; so does this reduce.
  const best = (candidates: ThemeRGB[]) =>
    candidates.reduce((winner, next) => (contrast(winner, highlight) <= contrast(next, highlight) ? next : winner));
  const themed = best([withAlpha(bg, 1), withAlpha(primary, 1)]);
  const highlightText =
    contrast(themed, highlight) >= MINIMUM_TEXT_CONTRAST ? themed : best([rgbHex(0x000000), rgbHex(0xffffff)]);
  return {
    isDark,
    windowBackground: surface,
    sidebarBackground: surface,
    contentBackground: surface,
    // ThemeTokens+Surface.swift: the surface every pane paints is the content background.
    surfaceBackground: surface,
    chromeBackground: mixed(bg, fg, isDark ? 0.05 : 0.035),
    elevatedBackground: mixed(bg, fg, isDark ? 0.07 : 0.02),
    stripBackground: surface,
    sidebarStep: withAlpha(fg, 0.04),
    textPrimary: primary,
    textSecondary: secondary,
    textTertiary: tertiary,
    hoverFill: hover,
    selectionFill: selection,
    secondarySelectionFill: accent ? withAlpha(accent, isDark ? 0.18 : 0.11) : withAlpha(fg, isDark ? 0.07 : 0.055),
    pressedFill: pressed,
    badgeFill: withAlpha(fg, isDark ? 0.14 : 0.1),
    separator: withAlpha(fg, isDark ? 0.08 : 0.07),
    paneBorder: withAlpha(fg, isDark ? 0.07 : 0.09),
    focusRing: accent ?? withAlpha(fg, 0.4),
    glassTint: withAlpha(bg, isDark ? 0.4 : 0.3),
    shadow: mixed(bg, BLACK, 0.85),
    // The config's selection only when text reads on it (ThemeTokens.swift: an inverse-video
    // selection would hide the text).
    textSelection:
      input.selectionBackground && contrast(primary, composited(input.selectionBackground, bg)) >= MINIMUM_MARK_CONTRAST
        ? input.selectionBackground
        : mixed(bg, fg, 0.22),
    attention: status(3),
    danger: status(1),
    success: status(2),
    highlight,
    highlightText,
    accent: accent ?? primary,
    onAccent: (app && parseHex(app.tokens.onAccent)) || withAlpha(bg, 1),
    hasThemeAccent: input.palette.length >= 8,
    ansi: palette,
    backgroundOpacity: input.backgroundOpacity,
  };
}

/**
 * ThemeTokens.wallpaperTintOpacity: the alpha of the theme tint the window lays over a background
 * picture (WindowBackdrop, with no Opacity of the user's own). Dark themes keep a denser tint; lighter
 * and higher-contrast themes show more of the picture.
 */
export function wallpaperTintOpacity(tokens: ThemeTokens): number {
  const window = tokens.windowBackground;
  const headroom = clamp((contrast(tokens.textPrimary, window) - MINIMUM_TEXT_CONTRAST) / 8);
  const bias = Math.min(Math.max((luminance(window) - 0.18) * 0.12, -0.03), 0.08);
  const floor = tokens.isDark ? 0.62 : 0.56;
  return Math.min(Math.max(floor + (1 - headroom) * 0.1 + bias, 0.52), 0.76);
}

/**
 * The popup surface (OverlayMaterial.swift `ThemeTokens.opaqueOverlayFill`): the opaque window
 * background lifted by up to `lift` toward white, or on a dark theme whose text is lighter than its
 * page toward the text, stopping where secondary text would drop below 4.5:1 on a hovered row. A dark
 * theme with dark text (Hot Dog Stand's red) lifts toward white: toward the text would darken the card.
 */
export function opaqueOverlayFill(tokens: ThemeTokens, lift: number): ThemeRGB {
  const page = withAlpha(tokens.windowBackground, 1);
  const text = withAlpha(tokens.textPrimary, 1);
  if (!tokens.isDark || luminance(text) < luminance(page)) return mixed(page, WHITE, lift);
  const secondary = withAlpha(tokens.textSecondary, 1);
  // Swift's `rounded()` rounds half away from zero; the lift is positive, so Math.round agrees.
  let step = Math.round(lift * 100) / 100;
  while (step > 0) {
    const fill = mixed(page, text, step);
    if (contrast(secondary, composited(tokens.hoverFill, fill)) >= MINIMUM_TEXT_CONTRAST) return fill;
    step -= 0.01;
  }
  return page;
}

/**
 * ThemeTokens.litGlyph: a lit control's glyph, the accent lifted toward the primary text just far
 * enough to contrast with the window at least as much as the rest ink (`textSecondary`).
 */
export function litGlyph(tokens: ThemeTokens): ThemeRGB {
  const surface = withAlpha(tokens.windowBackground, 1);
  const lit = composited(tokens.accent, surface);
  const primary = composited(tokens.textPrimary, surface);
  const floor = contrast(composited(tokens.textSecondary, surface), surface);
  if (contrast(lit, surface) >= floor) return lit;
  let low = 0;
  let high = 1;
  for (let step = 0; step < 12; step += 1) {
    const mid = (low + high) / 2;
    if (contrast(mixed(lit, primary, mid), surface) >= floor) high = mid;
    else low = mid;
  }
  return mixed(lit, primary, high);
}

/** `rgba(r, g, b, a)` with 0-255 channels, as WebTheme.css and AgentPaneTheme.css write it. */
export function css(color: ThemeRGB): string {
  const channel = (value: number) => Math.round(value * 255);
  const alpha = Math.round(color.alpha * 1000) / 1000;
  // Swift prints a whole Double with a decimal point ("1.0").
  const alphaText = Number.isInteger(alpha) ? alpha.toFixed(1) : String(alpha);
  return `rgba(${channel(color.red)}, ${channel(color.green)}, ${channel(color.blue)}, ${alphaText})`;
}

/** `#rrggbb` of the opaque color. */
export function hex(color: ThemeRGB): string {
  const channel = (value: number) =>
    Math.round(value * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(color.red)}${channel(color.green)}${channel(color.blue)}`;
}
