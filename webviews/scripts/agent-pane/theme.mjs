// The theme Swift hands the pane (`AgentPaneTheme.values`), derived the way
// `ThemeTokens.derive(from:)` derives it from a terminal theme. Keep in step with
// Packages/macOS/CmuxNext/Sources/CmuxNextDesign/ThemeTokens.swift and
// Sources/CmuxNextAgentPane/AgentPaneTheme.swift: the harness must color the
// pane as the app does.

import fs from "node:fs";

const rgb = (hex, alpha = 1) => ({
  r: ((hex >> 16) & 255) / 255,
  g: ((hex >> 8) & 255) / 255,
  b: (hex & 255) / 255,
  a: alpha,
});

/// `ThemeInput.ghosttyDefault`: the theme when the Ghostty config sets none.
export const ghosttyDefault = {
  background: rgb(0x282c34),
  foreground: rgb(0xffffff),
  palette: [
    0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6, 0x666666, 0xd54e53, 0xb9ca4a,
    0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
  ].map((hex) => rgb(hex)),
  backgroundOpacity: 1,
};

/// A theme from Ghostty's theme files (Resources/ghostty/themes/<name>), read as Ghostty
/// reads `palette = N=#rrggbb`, `background` and `foreground`. Missing entries keep the default's.
export function ghosttyThemeFile(file) {
  const theme = { ...ghosttyDefault, palette: [...ghosttyDefault.palette] };
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const match = /^\s*(palette|background|foreground)\s*=\s*(?:(\d+)=)?#?([0-9a-fA-F]{6})\s*$/.exec(line);
    if (!match) continue;
    const color = rgb(parseInt(match[3], 16));
    if (match[1] === "palette") theme.palette[Number(match[2])] = color;
    else theme[match[1]] = color;
  }
  return theme;
}

const luminance = ({ r, g, b }) => {
  const linear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
};
const contrast = (x, y) =>
  (Math.max(luminance(x), luminance(y)) + 0.05) / (Math.min(luminance(x), luminance(y)) + 0.05);
const mixed = (c, o, f) => {
  const t = Math.min(1, Math.max(0, f));
  return { r: c.r + (o.r - c.r) * t, g: c.g + (o.g - c.g) * t, b: c.b + (o.b - c.b) * t, a: c.a };
};
const withAlpha = (c, a) => ({ ...c, a });
const composited = (c, base) => withAlpha(mixed(base, withAlpha(c, 1), c.a), 1);
const white = rgb(0xffffff);
const black = rgb(0x000000);

function readable(color, surface, minimum) {
  if (contrast(color, surface) >= minimum) return color;
  const pole = luminance(surface) < 0.18 ? white : black;
  let step = 0;
  let candidate = color;
  while (step < 1 && contrast(candidate, surface) < minimum) {
    step += 0.02;
    candidate = mixed(color, pole, step);
  }
  return candidate;
}

function muted(color, target, limit, surface, minimum) {
  for (let fraction = limit; fraction > 0; fraction -= 0.01) {
    const candidate = mixed(color, target, fraction);
    if (contrast(candidate, surface) >= minimum) return candidate;
  }
  return color;
}

/// The `ThemeTokens` fields the pane uses.
export function themeTokens(input) {
  const bg = input.background;
  const fg = input.foreground;
  const isDark = luminance(bg) < luminance(fg);
  const pressed = withAlpha(fg, isDark ? 0.14 : 0.11);
  const worstSurface = composited(pressed, bg);
  const primary = readable(fg, worstSurface, 4.5);
  const palette = input.palette.length >= 8 ? input.palette : ghosttyDefault.palette;
  const highlight = readable(palette[4], bg, 3);
  // As ThemeTokens.derive: a theme color when one reads on the blue; black or white always reaches 4.5:1.
  const best = (colors) => colors.reduce((a, b) => (contrast(b, highlight) > contrast(a, highlight) ? b : a));
  const themed = best([withAlpha(bg, 1), withAlpha(primary, 1)]);
  const highlightText = contrast(themed, highlight) >= 4.5 ? themed : best([black, white]);
  return {
    isDark,
    contentBackground: withAlpha(bg, input.backgroundOpacity),
    elevatedBackground: mixed(bg, fg, isDark ? 0.07 : 0.02),
    textPrimary: primary,
    textSecondary: muted(primary, bg, 0.38, worstSurface, 4.5),
    textTertiary: muted(primary, bg, 0.55, worstSurface, 3),
    hoverFill: withAlpha(fg, isDark ? 0.06 : 0.05),
    selectionFill: withAlpha(fg, isDark ? 0.1 : 0.08),
    separator: withAlpha(fg, isDark ? 0.08 : 0.07),
    paneBorder: withAlpha(fg, isDark ? 0.07 : 0.09),
    shadow: mixed(bg, black, 0.85),
    attention: readable(palette[3], bg, 3),
    highlight,
    highlightText,
    danger: readable(palette[1], bg, 3),
  };
}

const css = (c) =>
  `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${Math.round(c.a * 1000) / 1000})`;

/// `AgentPaneTheme.values(tokens)`: the object `cmuxAcpmuxBridge.applyTheme` receives.
export function agentPaneTheme(input) {
  const t = themeTokens(input);
  const page = t.contentBackground;
  return {
    isDark: t.isDark,
    pageBackground: css(page),
    surfaceBackground: css(page),
    surfaceElevatedBackground: css(t.elevatedBackground),
    inputBackground: css(composited(t.hoverFill, page)),
    border: css(t.separator),
    borderStrong: css(t.paneBorder),
    text: css(t.textPrimary),
    mutedText: css(t.textSecondary),
    softText: css(t.textTertiary),
    accent: css(t.textPrimary),
    accentSoft: css(t.selectionFill),
    // Labels on the accent: the page background, opaque so a translucent backdrop doesn't thin them.
    accentText: css(withAlpha(page, 1)),
    warning: css(t.attention),
    // The action color (Send) and the glyph on it.
    highlight: css(t.highlight),
    highlightText: css(t.highlightText),
    danger: css(t.danger),
    shadow: css(t.shadow),
    // The terminal's ANSI colors in order, for syntax colors that follow the theme.
    // Each lifted to text contrast over the code card (the elevated surface).
    palette: (input.palette.length >= 8 ? input.palette : ghosttyDefault.palette)
      .slice(0, 16)
      .map((color) => css(readable(color, t.elevatedBackground, 4.5))),
  };
}
