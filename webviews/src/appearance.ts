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

export function resolveDiffViewerAppearance(appearance?: DiffViewerAppearance): ResolvedDiffViewerAppearance {
  const lightTheme = { ...defaultLightTheme, ...appearance?.themes?.light };
  const darkTheme = { ...defaultDarkTheme, ...appearance?.themes?.dark };
  lightTheme.foreground = readableColor(lightTheme.foreground, lightTheme.background, defaultLightTheme.foreground);
  lightTheme.selectionForeground = readableColor(lightTheme.selectionForeground, lightTheme.selectionBackground, defaultLightTheme.selectionForeground);
  darkTheme.foreground = readableColor(darkTheme.foreground, darkTheme.background, defaultDarkTheme.foreground);
  darkTheme.selectionForeground = readableColor(darkTheme.selectionForeground, darkTheme.selectionBackground, defaultDarkTheme.selectionForeground);
  return {
    backgroundOpacity: normalizedOpacity(appearance?.backgroundOpacity),
    fontFamily: appearance?.fontFamily ?? "Menlo",
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

export function applyDiffViewerAppearance(appearance?: DiffViewerAppearance) {
  if (!appearance) {
    return;
  }

  const lightTheme = appearance.themes?.light ?? {};
  const darkTheme = appearance.themes?.dark ?? {};
  const rootStyle = document.documentElement.style;

  // `--cmux-diff-bg` stays opaque: it is the base color the page blends against
  // for text, borders, and floating overlays (menus).
  rootStyle.setProperty("--cmux-diff-bg-light", colorString(lightTheme.background, "#ffffff"));
  rootStyle.setProperty("--cmux-diff-bg-dark", colorString(darkTheme.background, "#000000"));
  // Page fill behind the diff surface. Opaque themes (background-opacity 1) paint
  // the terminal color so loading and empty regions match the theme: the browser
  // pane behind a transparent diff page is a plain gray window backdrop, not the
  // terminal color (only transparent themes get a terminal-colored window-root
  // backdrop behind every pane). Transparent themes keep this clear so the blurred
  // backdrop shows. Mirrors `appearanceBackgroundColor`.
  const surfaceFillOpaque = normalizedOpacity(appearance.backgroundOpacity) >= 0.999;
  rootStyle.setProperty("--cmux-diff-surface-fill-light", surfaceFillOpaque ? colorString(lightTheme.background, "#ffffff") : "transparent");
  rootStyle.setProperty("--cmux-diff-surface-fill-dark", surfaceFillOpaque ? colorString(darkTheme.background, "#000000") : "transparent");
  rootStyle.setProperty("--cmux-diff-fg-light", colorString(lightTheme.foreground, "#000000"));
  rootStyle.setProperty("--cmux-diff-fg-dark", colorString(darkTheme.foreground, "#ffffff"));
  rootStyle.setProperty("--cmux-diff-addition-fg-light", semanticPaletteColor(lightTheme, ["10", "2"], "#257a3e"));
  rootStyle.setProperty("--cmux-diff-addition-fg-dark", semanticPaletteColor(darkTheme, ["10", "2"], "#8fd88f"));
  rootStyle.setProperty("--cmux-diff-deletion-fg-light", semanticPaletteColor(lightTheme, ["9", "1"], "#b42318"));
  rootStyle.setProperty("--cmux-diff-deletion-fg-dark", semanticPaletteColor(darkTheme, ["9", "1"], "#ff8a80"));
  rootStyle.setProperty("--cmux-diff-selection-bg-light", colorString(lightTheme.selectionBackground, "#abd8ff"));
  rootStyle.setProperty("--cmux-diff-selection-bg-dark", colorString(darkTheme.selectionBackground, "#3f638b"));
  rootStyle.setProperty("--cmux-diff-code-font-family", codeFontFamily(appearance.fontFamily));
  rootStyle.setProperty("--cmux-diff-font-size", `${metric(appearance.fontSize, 10)}px`);
  rootStyle.setProperty("--cmux-diff-line-height", `${metric(appearance.lineHeight, 20)}px`);
}

export function appearanceBackgroundColor(color: unknown, appearance?: DiffViewerAppearance) {
  // Transparent terminal themes let the cmux window backdrop show through, so
  // code surfaces paint no fill. Opaque themes get a solid fill.
  if (normalizedOpacity(appearance?.backgroundOpacity) < 0.999) {
    return "transparent";
  }
  return colorString(color, "#000000");
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

function semanticPaletteColor(theme: DiffViewerTheme, paletteKeys: string[], fallback: string): string {
  const palette = theme.palette ?? {};
  const candidate = paletteKeys.map((key) => palette[key]).find((value) => typeof value === "string" && value.trim() !== "");
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
  return 0.2126 * luminanceChannel(color.red) +
    0.7152 * luminanceChannel(color.green) +
    0.0722 * luminanceChannel(color.blue);
}

function luminanceChannel(value: number): number {
  const normalized = value / 255;
  return normalized <= 0.03928 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
}
