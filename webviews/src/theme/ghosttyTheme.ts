// Ghostty theme files (Resources/ghostty/themes, the 600+ themes the app ships): `key = value`
// lines, `palette = N=#rrggbb`. This reads the keys the app's ThemeBridge turns into a ThemeInput
// (background, foreground, palette 0-15, the selection colors) and the cursor colors, which the
// Settings theme preview draws.

/** One theme as the app and the gallery hand it to pages: hex strings, small and JSON-safe. */
export type GhosttyTheme = {
  name: string;
  background: string;
  foreground: string;
  /** ANSI 0-15; a missing index is null. */
  palette: (string | null)[];
  selectionBackground?: string;
  selectionForeground?: string;
  cursorColor?: string;
  cursorText?: string;
};

const HEX = /^#?[0-9a-fA-F]{6}$/;
const normal = (value: string) => (value.startsWith("#") ? value : `#${value}`).toLowerCase();

const OPTIONAL_KEYS = {
  "selection-background": "selectionBackground",
  "selection-foreground": "selectionForeground",
  "cursor-color": "cursorColor",
  "cursor-text": "cursorText",
} as const;

/** Parses a theme file; null when it names no background and foreground. */
export function parseGhosttyTheme(name: string, text: string): GhosttyTheme | null {
  let background: string | undefined;
  let foreground: string | undefined;
  const optional: Partial<Record<(typeof OPTIONAL_KEYS)[keyof typeof OPTIONAL_KEYS], string>> = {};
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
      else if (key in OPTIONAL_KEYS) optional[OPTIONAL_KEYS[key as keyof typeof OPTIONAL_KEYS]] = normal(value);
    }
  }
  if (!background || !foreground) return null;
  const theme: GhosttyTheme = { name, background, foreground, palette };
  if (optional.selectionBackground) theme.selectionBackground = optional.selectionBackground;
  if (optional.selectionForeground) theme.selectionForeground = optional.selectionForeground;
  if (optional.cursorColor) theme.cursorColor = optional.cursorColor;
  if (optional.cursorText) theme.cursorText = optional.cursorText;
  return theme;
}
