import { applyDiffTints } from "./diffWeight";
import { contrastBetween, mixColors, withMinimumContrast } from "./syntax-colors";
import { pageSyntaxVariable, syntaxRoleColors, type SyntaxRoleName } from "./syntax-theme";

export type DiffViewerTheme = {
  background?: string;
  foreground?: string;
  ghosttyName?: string;
  name?: string;
  palette?: Record<string, string>;
  selectionBackground?: string;
  selectionForeground?: string;
  type?: string;
};

export type DiffViewerAppearance = {
  backgroundOpacity?: number;
  fontFamily?: string;
  fontSize?: number;
  lineHeight?: number;
  theme?: {
    dark?: string;
    light?: string;
  };
  themes?: {
    dark?: DiffViewerTheme;
    light?: DiffViewerTheme;
  };
};

export type ResolvedDiffViewerAppearance = DiffViewerAppearance & {
  theme: {
    dark: string;
    light: string;
  };
  themes: {
    dark: DiffViewerTheme;
    light: DiffViewerTheme;
  };
};

const defaultLightTheme: DiffViewerTheme = {
  background: "#ffffff",
  foreground: "#000000",
  ghosttyName: "Apple System Colors Light",
  name: "cmux-ghostty-light",
  palette: {},
  selectionBackground: "#abd8ff",
  selectionForeground: "#000000",
  type: "light",
};

const defaultDarkTheme: DiffViewerTheme = {
  background: "#000000",
  foreground: "#ffffff",
  ghosttyName: "Apple System Colors",
  name: "cmux-ghostty-dark",
  palette: {},
  selectionBackground: "#3f638b",
  selectionForeground: "#ffffff",
  type: "dark",
};

type HostThemeWindow = Window & { cmuxTheme?: { current?: { terminal?: HostTerminalTheme } | null } };
type HostTerminalTheme = {
  type?: string;
  background?: string;
  foreground?: string;
  palette?: Record<string, string>;
  fontFamily?: string | null;
};

/**
 * The terminal's font family the host sends with its theme (WebTheme.swift `terminal.fontFamily`:
 * cmux.json's `terminal.fontFamily`, else the Ghostty config's), or null when it names none. Code
 * on the diff, markdown and editor pages draws in it, as in the terminal.
 */
export function hostTerminalFontFamily(): string | null {
  if (typeof window === "undefined") return null;
  const family = (window as HostThemeWindow).cmuxTheme?.current?.terminal?.fontFamily;
  return typeof family === "string" && family.trim() !== "" ? family.trim() : null;
}

/** The terminal theme the host sends with every theme change (WebTheme.swift `terminal`), or null. */
export function hostTerminalTheme(): DiffViewerTheme | null {
  if (typeof window === "undefined") return null;
  const terminal = (window as HostThemeWindow).cmuxTheme?.current?.terminal;
  if (!terminal || typeof terminal !== "object") return null;
  // Only the colors it names, so a missing one keeps the default theme's.
  const theme: DiffViewerTheme = {};
  if (typeof terminal.background === "string") theme.background = terminal.background;
  if (typeof terminal.foreground === "string") theme.foreground = terminal.foreground;
  if (terminal.palette && typeof terminal.palette === "object") theme.palette = terminal.palette;
  return theme;
}

/**
 * Runs `apply` now and after every host theme change (`cmux-theme`), so a page's code colors and
 * diff colors follow a Ghostty config edit in place. Returns the unsubscribe.
 */
export function followHostTerminalTheme(apply: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const listener = () => apply();
  window.addEventListener("cmux-theme", listener);
  apply();
  return () => window.removeEventListener("cmux-theme", listener);
}

/**
 * The page's appearance: the host's own when it sends one (its `themes`), else the terminal theme
 * of the page's scope (`window.cmuxTheme`), else the default terminal theme.
 */
export function resolveDiffViewerAppearance(appearance?: DiffViewerAppearance): ResolvedDiffViewerAppearance {
  const host = appearance?.themes ? null : hostTerminalTheme();
  const lightTheme = { ...defaultLightTheme, ...host, ...appearance?.themes?.light };
  const darkTheme = { ...defaultDarkTheme, ...host, ...appearance?.themes?.dark };
  lightTheme.foreground = readableColor(lightTheme.foreground, lightTheme.background, defaultLightTheme.foreground);
  lightTheme.selectionForeground = readableColor(
    lightTheme.selectionForeground,
    lightTheme.selectionBackground,
    defaultLightTheme.selectionForeground,
  );
  darkTheme.foreground = readableColor(darkTheme.foreground, darkTheme.background, defaultDarkTheme.foreground);
  darkTheme.selectionForeground = readableColor(
    darkTheme.selectionForeground,
    darkTheme.selectionBackground,
    defaultDarkTheme.selectionForeground,
  );
  return {
    backgroundOpacity: normalizedOpacity(appearance?.backgroundOpacity),
    fontFamily: appearance?.fontFamily ?? hostTerminalFontFamily() ?? "Menlo",
    fontSize: metric(appearance?.fontSize, 10),
    lineHeight: metric(appearance?.lineHeight, 20),
    theme: {
      light: appearance?.theme?.light ?? lightTheme.name ?? "cmux-ghostty-light",
      dark: appearance?.theme?.dark ?? darkTheme.name ?? "cmux-ghostty-dark",
    },
    themes: {
      light: lightTheme,
      dark: darkTheme,
    },
  };
}

/// Diff Colors (Settings > Diff Viewer, `diff.colors`): where additions and deletions get their
/// colors. `theme` takes the terminal palette's green and red, `muted` mixes those toward the
/// background, `standard` keeps fixed GitHub-style colors.
export type DiffChangeColors = "theme" | "muted" | "standard";

const STANDARD_ADDITION = { light: "#257a3e", dark: "#8fd88f" } as const;
const STANDARD_DELETION = { light: "#b42318", dark: "#ff8a80" } as const;
/// How far Muted moves the theme's color toward the background, before restoring 4.5:1.
const MUTED_MIX = 0.4;

let changeColors: DiffChangeColors = "theme";
let appliedAppearance: DiffViewerAppearance | undefined;

/// Sets the Diff Colors mode (`undefined` is the default, Theme) and recolors the page in place.
export function setDiffChangeColors(colors: DiffChangeColors | undefined) {
  const next = colors ?? "theme";
  if (next === changeColors) return;
  changeColors = next;
  applyDiffTints(document.documentElement.style, changeColors);
  applyDiffViewerAppearance(appliedAppearance);
}

export function applyDiffViewerAppearance(appearance?: DiffViewerAppearance) {
  if (!appearance) {
    return;
  }
  appliedAppearance = appearance;

  const lightTheme = appearance.themes?.light ?? {};
  const darkTheme = appearance.themes?.dark ?? {};
  const rootStyle = document.documentElement.style;

  // `--cmux-diff-bg` is the opaque terminal theme color. styles.css derives
  // `--cmux-diff-viewer-bg` from it, the one background of the whole viewer
  // (page, toolbar, file headers, files sidebar and tree).
  rootStyle.setProperty("--cmux-diff-bg-light", colorString(lightTheme.background, "#ffffff"));
  rootStyle.setProperty("--cmux-diff-bg-dark", colorString(darkTheme.background, "#000000"));
  rootStyle.setProperty("--cmux-diff-fg-light", colorString(lightTheme.foreground, "#000000"));
  rootStyle.setProperty("--cmux-diff-fg-dark", colorString(darkTheme.foreground, "#ffffff"));
  for (const [type, theme] of [
    ["light", lightTheme],
    ["dark", darkTheme],
  ] as const) {
    rootStyle.setProperty(
      `--cmux-diff-addition-fg-${type}`,
      changeColor(theme, type, ["10", "2"], STANDARD_ADDITION[type]),
    );
    rootStyle.setProperty(
      `--cmux-diff-deletion-fg-${type}`,
      changeColor(theme, type, ["9", "1"], STANDARD_DELETION[type]),
    );
    // A modified file in the files list: the palette's blue, else the theme's own text color
    // (no fixed blue: the page paints the theme).
    rootStyle.setProperty(
      `--cmux-diff-modified-fg-${type}`,
      semanticPaletteColor(theme, ["12", "4"], colorString(theme.foreground, type === "light" ? "#000000" : "#ffffff")),
    );
  }
  rootStyle.setProperty("--cmux-diff-selection-bg-light", colorString(lightTheme.selectionBackground, "#abd8ff"));
  rootStyle.setProperty("--cmux-diff-selection-bg-dark", colorString(darkTheme.selectionBackground, "#3f638b"));
  rootStyle.setProperty("--cmux-diff-code-font-family", codeFontFamily(appearance.fontFamily));
  rootStyle.setProperty("--cmux-diff-font-size", `${metric(appearance.fontSize, 10)}px`);
  rootStyle.setProperty("--cmux-diff-line-height", `${metric(appearance.lineHeight, 20)}px`);
  // Code colors (syntax-theme.ts): each token rule reads its role's variable, so this recolors
  // code in place.
  for (const [type, theme] of [
    ["light", lightTheme],
    ["dark", darkTheme],
  ] as const) {
    const colors = syntaxColorsFor(theme, type);
    for (const role of Object.keys(colors) as SyntaxRoleName[]) {
      rootStyle.setProperty(pageSyntaxVariable(type, role), colors[role]);
    }
  }
}

/** The background code colors are measured on: the theme's, else black or white for its type. */
export function syntaxContrastBackground(theme: DiffViewerTheme, type: "light" | "dark"): string {
  if (typeof theme.background === "string" && theme.background.trim() !== "") return theme.background.trim();
  return type === "light" ? "#ffffff" : "#000000";
}

/** Each code role's color for a terminal theme (syntax-theme.ts), on its own background. */
export function syntaxColorsFor(theme: DiffViewerTheme, type: "light" | "dark") {
  const background = syntaxContrastBackground(theme, type);
  const foreground = readableColor(theme.foreground, background, type === "light" ? "#000000" : "#ffffff");
  return syntaxRoleColors(theme.palette ?? {}, type, background, foreground);
}

export function appearanceBackgroundColor(_color: unknown, _appearance?: DiffViewerAppearance) {
  return "transparent";
}

export function readableColor(value: unknown, background: unknown, fallback: string | undefined): string {
  const color = colorString(value, fallback ?? "#000000");
  const parsedColor = parseHexColor(color);
  const parsedBackground = parseHexColor(colorString(background, "#000000"));
  if (!parsedColor || !parsedBackground) {
    return color;
  }
  if (contrastRatio(parsedColor, parsedBackground) >= 4.5) {
    return color;
  }
  const black: RGBColor = { blue: 0, green: 0, red: 0 };
  const white: RGBColor = { blue: 255, green: 255, red: 255 };
  return contrastRatio(black, parsedBackground) >= contrastRatio(white, parsedBackground) ? "#000000" : "#ffffff";
}

/// An addition or deletion color in the current Diff Colors mode.
function changeColor(theme: DiffViewerTheme, type: "light" | "dark", paletteKeys: string[], standard: string): string {
  if (changeColors === "standard") return standard;
  const themed = semanticPaletteColor(theme, paletteKeys, standard);
  if (changeColors === "theme") return themed;
  const background = syntaxContrastBackground(theme, type);
  const foreground = readableColor(theme.foreground, background, type === "light" ? "#000000" : "#ffffff");
  const muted = withMinimumContrast(mixColors(themed, background, MUTED_MIX), background, foreground, 4.5);
  // A color that cannot be measured (not hex) keeps the theme's own, which already reads.
  return (contrastBetween(muted, background) ?? 0) >= 4.5 ? muted : themed;
}

function semanticPaletteColor(theme: DiffViewerTheme, paletteKeys: string[], fallback: string): string {
  const palette = theme.palette ?? {};
  const candidate = paletteKeys
    .map((key) => palette[key])
    .find((value) => typeof value === "string" && value.trim() !== "");
  if (meetsContrast(candidate, theme.background, 4.5)) {
    return colorString(candidate, fallback);
  }
  if (meetsContrast(fallback, theme.background, 4.5)) {
    return fallback;
  }
  return readableColor(candidate, theme.background, fallback);
}

function colorString(value: unknown, fallback: string) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

function codeFontFamily(fontFamily: unknown) {
  const family = typeof fontFamily === "string" && fontFamily.trim() !== "" ? fontFamily.trim() : "Menlo";
  return `${JSON.stringify(family)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}

function metric(value: unknown, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

function normalizedOpacity(value: unknown) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 1;
  }
  return Math.max(0, Math.min(1, value));
}

function meetsContrast(value: unknown, background: unknown, minimumRatio: number): boolean {
  const parsedColor = parseHexColor(colorString(value, ""));
  const parsedBackground = parseHexColor(colorString(background, "#000000"));
  return Boolean(parsedColor && parsedBackground && contrastRatio(parsedColor, parsedBackground) >= minimumRatio);
}

type RGBColor = {
  blue: number;
  green: number;
  red: number;
};

function parseHexColor(value: string): RGBColor | null {
  const trimmed = value.trim();
  const short = trimmed.match(/^#([0-9a-f]{3})$/i);
  if (short) {
    const [, hex] = short;
    return {
      red: Number.parseInt(hex[0] + hex[0], 16),
      green: Number.parseInt(hex[1] + hex[1], 16),
      blue: Number.parseInt(hex[2] + hex[2], 16),
    };
  }
  const long = trimmed.match(/^#([0-9a-f]{6})$/i);
  if (!long) {
    return null;
  }
  const [, hex] = long;
  return {
    red: Number.parseInt(hex.slice(0, 2), 16),
    green: Number.parseInt(hex.slice(2, 4), 16),
    blue: Number.parseInt(hex.slice(4, 6), 16),
  };
}

function contrastRatio(foreground: RGBColor, background: RGBColor): number {
  const lighter = Math.max(relativeLuminance(foreground), relativeLuminance(background));
  const darker = Math.min(relativeLuminance(foreground), relativeLuminance(background));
  return (lighter + 0.05) / (darker + 0.05);
}

function relativeLuminance(color: RGBColor): number {
  return (
    0.2126 * luminanceChannel(color.red) +
    0.7152 * luminanceChannel(color.green) +
    0.0722 * luminanceChannel(color.blue)
  );
}

function luminanceChannel(value: number): number {
  const normalized = value / 255;
  return normalized <= 0.03928 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
}
