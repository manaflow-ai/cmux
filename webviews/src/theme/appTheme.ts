// The app theme: cmux's chrome tokens (surfaces, text levels, separators, accent, status colors),
// derived from a terminal (Ghostty) palette so that every bundled theme also works as the app
// theme. One pure module, the contract the native chrome (Swift), the web pages and the Settings
// preview share:
//
//   - APP_THEME_TOKENS names every token, its CSS variable and its role;
//   - APP_THEME_CONTRACT lists every foreground/background pair and its WCAG 2 minimum
//     (4.5:1 for text, 3:1 for UI marks such as the accent, focus ring, icons and control edges);
//   - deriveAppTheme(colors) returns opaque `#rrggbb` tokens that meet every pair.
//
// Colors start from the theme and move only as far as a contrast target needs: a token keeps its
// OKLCH hue and chroma and changes lightness (color.ts). The accent is neutral: the theme
// foreground's lightness without hue (the no-blue rule; never a palette slot such as ANSI 4).
// No hue is hard-coded. test/app-theme.test.ts checks every pair on all bundled themes.
import {
  BLACK,
  WHITE,
  contrast,
  fromOklch,
  luminance,
  mix,
  parseHex,
  quantized,
  toHex,
  toOklch,
  type RGB,
} from "./color";

/** The terminal colors the derivation reads (a GhosttyTheme has this shape). */
export type TerminalColors = {
  background: string;
  foreground: string;
  /** ANSI 0-15; a missing index is null. */
  palette: ReadonlyArray<string | null>;
};

export type AppTokenName =
  | "window"
  | "sidebar"
  | "content"
  | "elevated"
  | "control"
  | "hover"
  | "pressed"
  | "selection"
  | "separator"
  | "controlStroke"
  | "text"
  | "textSecondary"
  | "icon"
  | "accent"
  | "onAccent"
  | "accentText"
  | "focusRing"
  | "danger"
  | "warning"
  | "success";

export type AppTokenRole = "surface" | "text" | "ui" | "decorative";

export type AppTokenSpec = { variable: string; role: AppTokenRole; description: string };

/** Every token: its CSS variable (`--cmux-app-*`), role and use. */
export const APP_THEME_TOKENS: Readonly<Record<AppTokenName, AppTokenSpec>> = {
  window: { variable: "--cmux-app-window", role: "surface", description: "Window background." },
  sidebar: { variable: "--cmux-app-sidebar", role: "surface", description: "Sidebar background." },
  content: { variable: "--cmux-app-content", role: "surface", description: "Content and pane background." },
  elevated: { variable: "--cmux-app-elevated", role: "surface", description: "Menus, popovers and sheets." },
  control: { variable: "--cmux-app-control", role: "surface", description: "Fields, buttons and toggle tracks." },
  hover: { variable: "--cmux-app-hover", role: "surface", description: "A row or control under the pointer." },
  pressed: { variable: "--cmux-app-pressed", role: "surface", description: "A row or control while pressed." },
  selection: { variable: "--cmux-app-selection", role: "surface", description: "A selected row (accent tint)." },
  separator: {
    variable: "--cmux-app-separator",
    role: "decorative",
    description: "Hairlines between groups and rows; decorative, so no contrast minimum (WCAG 1.4.11).",
  },
  controlStroke: {
    variable: "--cmux-app-control-stroke",
    role: "ui",
    description: "The edge of an off toggle, radio or checkbox, and a field's focus-less outline.",
  },
  text: { variable: "--cmux-app-text", role: "text", description: "Primary text." },
  textSecondary: { variable: "--cmux-app-text-secondary", role: "text", description: "Help and secondary text." },
  icon: { variable: "--cmux-app-icon", role: "ui", description: "Icons and glyphs." },
  accent: {
    variable: "--cmux-app-accent",
    role: "ui",
    description: "On toggles, selected indicators and default buttons.",
  },
  onAccent: { variable: "--cmux-app-on-accent", role: "text", description: "Text and glyphs on the accent." },
  accentText: { variable: "--cmux-app-accent-text", role: "text", description: "Links and accented labels." },
  focusRing: { variable: "--cmux-app-focus-ring", role: "ui", description: "Keyboard focus ring." },
  danger: { variable: "--cmux-app-danger", role: "text", description: "Errors and destructive actions." },
  warning: { variable: "--cmux-app-warning", role: "text", description: "Warnings." },
  success: { variable: "--cmux-app-success", role: "text", description: "Success and healthy states." },
};

export const TEXT_MINIMUM = 4.5;
export const UI_MINIMUM = 3;

const PLAIN_SURFACES: AppTokenName[] = ["window", "sidebar", "content", "elevated"];
const TEXT_SURFACES: AppTokenName[] = [...PLAIN_SURFACES, "control", "hover", "pressed", "selection"];
const STATUS_SURFACES: AppTokenName[] = [...PLAIN_SURFACES, "hover"];

export type ContrastPair = { token: AppTokenName; on: AppTokenName; min: number };

/** Every foreground/background pair the tokens are used in, with its WCAG 2 minimum. */
export const APP_THEME_CONTRACT: ReadonlyArray<ContrastPair> = [
  ...TEXT_SURFACES.map((on) => ({ token: "text" as const, on, min: TEXT_MINIMUM })),
  ...TEXT_SURFACES.map((on) => ({ token: "textSecondary" as const, on, min: TEXT_MINIMUM })),
  ...TEXT_SURFACES.map((on) => ({ token: "icon" as const, on, min: UI_MINIMUM })),
  ...[...PLAIN_SURFACES, "control" as const].map((on) => ({ token: "controlStroke" as const, on, min: UI_MINIMUM })),
  ...PLAIN_SURFACES.map((on) => ({ token: "accent" as const, on, min: UI_MINIMUM })),
  ...PLAIN_SURFACES.map((on) => ({ token: "focusRing" as const, on, min: UI_MINIMUM })),
  { token: "onAccent", on: "accent", min: TEXT_MINIMUM },
  ...[...STATUS_SURFACES, "selection" as const].map((on) => ({ token: "accentText" as const, on, min: TEXT_MINIMUM })),
  ...STATUS_SURFACES.map((on) => ({ token: "danger" as const, on, min: TEXT_MINIMUM })),
  ...STATUS_SURFACES.map((on) => ({ token: "warning" as const, on, min: TEXT_MINIMUM })),
  ...STATUS_SURFACES.map((on) => ({ token: "success" as const, on, min: TEXT_MINIMUM })),
];

export type AppTheme = {
  isDark: boolean;
  tokens: Readonly<Record<AppTokenName, string>>;
};

/** Ghostty's own defaults, for a theme that omits a slot. */
const GHOSTTY_DEFAULT_PALETTE = [
  "#1d1f21",
  "#cc6666",
  "#b5bd68",
  "#f0c674",
  "#81a2be",
  "#b294bb",
  "#8abeb7",
  "#c5c8c6",
  "#666666",
  "#d54e53",
  "#b9ca4a",
  "#e7c547",
  "#7aa6da",
  "#c397d8",
  "#70c0b1",
  "#eaeaea",
];

type Constraint = { on: RGB; min: number };

const meets = (color: RGB, constraints: Constraint[]) =>
  constraints.every((constraint) => contrast(color, constraint.on) >= constraint.min);

/**
 * `color` as close to itself as the constraints allow: unchanged when it already meets them, else
 * the smallest OKLCH lightness change (hue kept, chroma reduced only to stay in gamut), toward the
 * direction away from the backgrounds first. Every check runs on the 8-bit color a screen shows.
 */
export function fit(color: RGB, constraints: Constraint[], prefer?: "lighter" | "darker"): RGB {
  const start = quantized(color);
  if (meets(start, constraints)) return start;
  const lch = toOklch(start);
  const darkBackgrounds =
    constraints.reduce((sum, constraint) => sum + luminance(constraint.on), 0) / Math.max(constraints.length, 1) < 0.18;
  const first = prefer ?? (darkBackgrounds ? "lighter" : "darker");
  for (const direction of [first, first === "lighter" ? "darker" : "lighter"] as const) {
    const pole = direction === "lighter" ? 1 : 0;
    const at = (t: number) => quantized(fromOklch({ ...lch, l: lch.l + (pole - lch.l) * t }));
    if (!meets(at(1), constraints)) continue;
    let low = 0;
    let high = 1;
    for (let step = 0; step < 28; step += 1) {
      const middle = (low + high) / 2;
      if (meets(at(middle), constraints)) high = middle;
      else low = middle;
    }
    return at(high);
  }
  const white = Math.min(...constraints.map((constraint) => contrast(WHITE, constraint.on)));
  const black = Math.min(...constraints.map((constraint) => contrast(BLACK, constraint.on)));
  return white >= black ? WHITE : BLACK;
}

const rgbOf = (hex: string | null | undefined, fallback: string): RGB =>
  (hex ? parseHex(hex) : null) ?? parseHex(fallback)!;

/** `color` without hue: its OKLCH lightness at zero chroma (a gray). */
export function neutral(color: RGB): RGB {
  return fromOklch({ l: toOklch(color).l, c: 0, h: 0 });
}

/** The more colorful of two slots (the normal and the bright variant of one ANSI color). */
function colorful(palette: ReadonlyArray<RGB>, normal: number, bright: number): RGB {
  return toOklch(palette[bright]!).c > toOklch(palette[normal]!).c + 0.02 ? palette[bright]! : palette[normal]!;
}

/** Surface tint strengths, tried in order: a mid-luminance background (neither black nor white
 * text reads on every tinted surface) gets flatter surfaces until every pair passes. At 0 every
 * surface is the background, where a passing text color always exists. */
const TINT_SCALES = [1, 0.7, 0.45, 0.25, 0.1, 0];

/** The app tokens of a terminal palette. Every pair in APP_THEME_CONTRACT meets its minimum. */
export function deriveAppTheme(colors: TerminalColors): AppTheme {
  let theme = derive(colors, 1);
  for (const scale of TINT_SCALES.slice(1)) {
    if (contrastReport(theme).every((result) => result.pass)) break;
    theme = derive(colors, scale);
  }
  return theme;
}

function derive(colors: TerminalColors, tint: number): AppTheme {
  const bg = rgbOf(colors.background, "#282c34");
  const fg = rgbOf(colors.foreground, "#ffffff");
  const palette = GHOSTTY_DEFAULT_PALETTE.map((fallback, index) => rgbOf(colors.palette[index], fallback));
  const isDark = luminance(bg) < luminance(fg);

  const tokens = {} as Record<AppTokenName, RGB>;
  tokens.window = quantized(bg);
  tokens.content = quantized(bg);
  tokens.sidebar = quantized(mix(bg, fg, (isDark ? 0.04 : 0.035) * tint));
  tokens.elevated = quantized(isDark ? mix(bg, fg, 0.075 * tint) : mix(bg, WHITE, 0.7 * tint));
  tokens.control = quantized(mix(bg, fg, (isDark ? 0.1 : 0.065) * tint));
  tokens.hover = quantized(mix(bg, fg, (isDark ? 0.06 : 0.045) * tint));
  tokens.pressed = quantized(mix(bg, fg, (isDark ? 0.12 : 0.09) * tint));
  tokens.separator = quantized(mix(bg, fg, isDark ? 0.13 : 0.11));
  const on = (names: AppTokenName[], min: number): Constraint[] => names.map((name) => ({ on: tokens[name], min }));

  // The accent: a neutral from the theme's foreground (the no-blue rule: never a palette hue such
  // as ANSI 4), light enough (dark themes) or dark enough (light themes) to read as a mark on
  // every surface and to carry text in the window color (dark) or white (light).
  const onAccentWanted = isDark ? tokens.window : WHITE;
  tokens.accent = fit(
    neutral(fg),
    [...on(PLAIN_SURFACES, UI_MINIMUM), { on: onAccentWanted, min: TEXT_MINIMUM }],
    isDark ? "lighter" : "darker",
  );
  tokens.focusRing = tokens.accent;
  tokens.onAccent = meets(onAccentWanted, [{ on: tokens.accent, min: TEXT_MINIMUM }])
    ? onAccentWanted
    : fit(isDark ? BLACK : WHITE, [{ on: tokens.accent, min: TEXT_MINIMUM }]);
  tokens.selection = quantized(mix(bg, tokens.accent, (isDark ? 0.26 : 0.16) * tint));

  tokens.text = fit(fg, on(TEXT_SURFACES, TEXT_MINIMUM));
  tokens.textSecondary = fit(
    mix(tokens.text, bg, 0.34),
    on(TEXT_SURFACES, TEXT_MINIMUM),
    isDark ? "lighter" : "darker",
  );
  tokens.icon = fit(mix(tokens.text, bg, 0.3), on(TEXT_SURFACES, UI_MINIMUM), isDark ? "lighter" : "darker");
  tokens.controlStroke = fit(
    mix(bg, fg, 0.42),
    on([...PLAIN_SURFACES, "control"], UI_MINIMUM),
    isDark ? "lighter" : "darker",
  );
  const away = isDark ? "lighter" : "darker";
  tokens.accentText = fit(tokens.accent, on([...STATUS_SURFACES, "selection"], TEXT_MINIMUM), away);
  tokens.danger = fit(colorful(palette, 1, 9), on(STATUS_SURFACES, TEXT_MINIMUM), away);
  tokens.warning = fit(colorful(palette, 3, 11), on(STATUS_SURFACES, TEXT_MINIMUM), away);
  tokens.success = fit(colorful(palette, 2, 10), on(STATUS_SURFACES, TEXT_MINIMUM), away);

  const hex = Object.fromEntries(Object.entries(tokens).map(([name, color]) => [name, toHex(color)]));
  return { isDark, tokens: hex as Record<AppTokenName, string> };
}

export type ContrastResult = ContrastPair & { ratio: number; pass: boolean };

/** Every contract pair of a derived theme, with its measured ratio. */
export function contrastReport(theme: AppTheme): ContrastResult[] {
  return APP_THEME_CONTRACT.map((pair) => {
    const ratio = contrast(parseHex(theme.tokens[pair.token])!, parseHex(theme.tokens[pair.on])!);
    return { ...pair, ratio, pass: ratio >= pair.min };
  });
}

/** The tokens as CSS custom properties (`--cmux-app-*`), for a page or a preview element. */
export function appThemeVariables(theme: AppTheme): Record<string, string> {
  return Object.fromEntries(
    (Object.keys(APP_THEME_TOKENS) as AppTokenName[]).map((name) => [
      APP_THEME_TOKENS[name].variable,
      theme.tokens[name],
    ]),
  );
}
