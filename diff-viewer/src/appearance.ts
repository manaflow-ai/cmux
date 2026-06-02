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
  const lightBackground = colorString(lightTheme.background, "#ffffff");
  const darkBackground = colorString(darkTheme.background, "#000000");
  const opacity = normalizedOpacity(appearance.backgroundOpacity);
  const rootStyle = document.documentElement.style;

  rootStyle.setProperty("--cmux-diff-bg-opacity", roundedNumber(opacity));
  rootStyle.setProperty("--cmux-diff-bg-opacity-percent", `${roundedNumber(opacity * 100)}%`);
  rootStyle.setProperty("--cmux-diff-bg-base-light", lightBackground);
  rootStyle.setProperty("--cmux-diff-bg-base-dark", darkBackground);
  rootStyle.setProperty("--cmux-diff-bg-light", backgroundColorWithOpacity(lightBackground, opacity));
  rootStyle.setProperty("--cmux-diff-bg-dark", backgroundColorWithOpacity(darkBackground, opacity));
  rootStyle.setProperty("--cmux-diff-fg-light", colorString(lightTheme.foreground, "#000000"));
  rootStyle.setProperty("--cmux-diff-fg-dark", colorString(darkTheme.foreground, "#ffffff"));
  rootStyle.setProperty("--cmux-diff-selection-bg-light", colorString(lightTheme.selectionBackground, "#abd8ff"));
  rootStyle.setProperty("--cmux-diff-selection-bg-dark", colorString(darkTheme.selectionBackground, "#3f638b"));
  rootStyle.setProperty("--cmux-diff-code-font-family", codeFontFamily(appearance.fontFamily));
  rootStyle.setProperty("--cmux-diff-font-size", `${metric(appearance.fontSize, 10)}px`);
  rootStyle.setProperty("--cmux-diff-line-height", `${metric(appearance.lineHeight, 20)}px`);
}

export function appearanceBackgroundColor(color: unknown, appearance?: DiffViewerAppearance) {
  return backgroundColorWithOpacity(colorString(color, "#000000"), normalizedOpacity(appearance?.backgroundOpacity));
}

function backgroundColorWithOpacity(color: string, opacity: number) {
  const rgb = hexRGB(color);
  if (!rgb) {
    return `color-mix(in srgb, ${color} ${roundedNumber(opacity * 100)}%, transparent)`;
  }
  return `rgb(${rgb.red} ${rgb.green} ${rgb.blue} / ${roundedNumber(opacity)})`;
}

function colorString(value: unknown, fallback: string) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

function codeFontFamily(fontFamily: unknown) {
  const family = typeof fontFamily === "string" && fontFamily.trim() !== "" ? fontFamily.trim() : "Menlo";
  return `${JSON.stringify(family)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}

function hexRGB(color: string) {
  let hex = color.trim();
  if (!hex.startsWith("#")) {
    return null;
  }
  hex = hex.slice(1);
  if (hex.length === 3) {
    hex = hex.split("").map((digit) => `${digit}${digit}`).join("");
  }
  if (!/^[\da-f]{6}$/i.test(hex)) {
    return null;
  }
  const value = Number.parseInt(hex, 16);
  return {
    blue: value & 0xff,
    green: (value >> 8) & 0xff,
    red: (value >> 16) & 0xff,
  };
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

function roundedNumber(value: number) {
  return Number(value.toFixed(4)).toString();
}
