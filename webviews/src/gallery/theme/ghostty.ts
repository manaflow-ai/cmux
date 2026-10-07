// Ghostty theme files (Resources/ghostty/themes, the 600+ themes the app ships): `key = value`
// lines, `palette = N=#rrggbb`. The gallery reads only the keys the app's ThemeBridge turns into a
// ThemeInput: background, foreground, palette 0-15 and the selection colors.

/** One theme as the gallery ships it: hex strings, so it stays small and JSON-safe. */
export type GhosttyTheme = {
  name: string;
  background: string;
  foreground: string;
  /** ANSI 0-15; a missing index is null. */
  palette: (string | null)[];
  selectionBackground?: string;
  selectionForeground?: string;
};

const HEX = /^#?[0-9a-fA-F]{6}$/;
const normal = (value: string) => (value.startsWith("#") ? value : `#${value}`).toLowerCase();

/** Parses a theme file; null when it names no background and foreground. */
export function parseGhosttyTheme(name: string, text: string): GhosttyTheme | null {
  let background: string | undefined;
  let foreground: string | undefined;
  let selectionBackground: string | undefined;
  let selectionForeground: string | undefined;
  const palette: (string | null)[] = Array.from({ length: 16 }, () => null);
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/^﻿/, "").trim();
    if (!line || line.startsWith("#")) continue;
    const equals = line.indexOf("=");
    if (equals < 0) continue;
    const key = line.slice(0, equals).trim();
    const value = line.slice(equals + 1).trim();
    if (key === "palette") {
      const match = /^(\d+)\s*=\s*(\S+)$/.exec(value);
      const index = match ? Number(match[1]) : -1;
      if (match && index >= 0 && index < 16 && HEX.test(match[2]!)) palette[index] = normal(match[2]!);
    } else if (HEX.test(value)) {
      if (key === "background") background = normal(value);
      else if (key === "foreground") foreground = normal(value);
      else if (key === "selection-background") selectionBackground = normal(value);
      else if (key === "selection-foreground") selectionForeground = normal(value);
    }
  }
  if (!background || !foreground) return null;
  return { name, background, foreground, palette, selectionBackground, selectionForeground };
}

/** Whether a theme is dark: its background is darker than its foreground (ThemeTokens.isDark). */
export function themeIsDark(theme: GhosttyTheme): boolean {
  const lum = (hex: string) => {
    const value = parseInt(hex.slice(1), 16);
    const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
    return (
      0.2126 * linear(((value >> 16) & 0xff) / 255) +
      0.7152 * linear(((value >> 8) & 0xff) / 255) +
      0.0722 * linear((value & 0xff) / 255)
    );
  };
  return lum(theme.background) < lum(theme.foreground);
}

/** The app's default pair (appearance.ts): Apple System Colors, dark and light. */
export const DEFAULT_DARK_THEME = "Apple System Colors";
export const DEFAULT_LIGHT_THEME = "Apple System Colors Light";
