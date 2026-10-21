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
  const primary = readable(fg, worstSurface, MINIMUM_TEXT_CONTRAST);
  const secondary = muted(primary, bg, 0.38, worstSurface, MINIMUM_TEXT_CONTRAST);
  const tertiary = muted(primary, bg, 0.55, worstSurface, MINIMUM_MARK_CONTRAST);
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
