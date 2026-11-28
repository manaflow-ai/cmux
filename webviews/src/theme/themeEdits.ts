// Per-token color edits to themes (appearance.themeEdits, cx-wqn5): `{"<theme>/<token>": "#rrggbb"}`,
// the same keys and tokens as the app's ThemeEditsSetting. Edits derive "Rose Pine (custom)" and
// never change the theme itself: the theme's colors, then its edits.
import type { GhosttyTheme } from "./ghosttyTheme";

/**
 * The tokens an edit can set: background, foreground, cursor, selection, ANSI 0-15, and the app
 * accent for this theme (`accent`, over appearance.accent; no Ghostty color).
 */
export const THEME_EDIT_TOKENS = [
  "background",
  "foreground",
  "cursor",
  "selection",
  ...Array.from({ length: 16 }, (_, index) => String(index)),
  "accent",
] as const;

export type ThemeEditToken = (typeof THEME_EDIT_TOKENS)[number];
export type ThemeEditMap = Readonly<Record<string, string>>;

const COLOR = /^#[0-9a-fA-F]{6}$/;

/** The key of one edit. */
export function themeEditKey(theme: string, token: ThemeEditToken): string {
  return `${theme}/${token}`;
}

/** `theme`'s edits, token to `#rrggbb`; bad entries are left out, as the app drops them. */
export function editsFor(
  edits: ThemeEditMap | null | undefined,
  theme: string,
): Partial<Record<ThemeEditToken, string>> {
  const found: Partial<Record<ThemeEditToken, string>> = {};
  if (!edits) return found;
  for (const [key, value] of Object.entries(edits)) {
    const slash = key.lastIndexOf("/");
    if (slash < 0 || key.slice(0, slash) !== theme || typeof value !== "string" || !COLOR.test(value)) continue;
    const token = key.slice(slash + 1);
    if ((THEME_EDIT_TOKENS as readonly string[]).includes(token)) found[token as ThemeEditToken] = value.toLowerCase();
  }
  return found;
}

/** Whether `theme` has edits: it shows as "<theme> (custom)". */
export function isEdited(edits: ThemeEditMap | null | undefined, theme: string): boolean {
  return Object.keys(editsFor(edits, theme)).length > 0;
}

/** `theme` with its edits applied; the same object when it has none. */
export function withEdits(theme: GhosttyTheme, edits: ThemeEditMap | null | undefined): GhosttyTheme {
  const found = editsFor(edits, theme.name);
  if (Object.keys(found).length === 0) return theme;
  const palette = theme.palette.map((color, index) => found[String(index) as ThemeEditToken] ?? color);
  return {
    ...theme,
    background: found.background ?? theme.background,
    foreground: found.foreground ?? theme.foreground,
    cursorColor: found.cursor ?? theme.cursorColor,
    selectionBackground: found.selection ?? theme.selectionBackground,
    accent: found.accent ?? theme.accent,
    palette,
  };
}

/** Every theme in `colors` with its edits applied. */
export function withAllEdits(
  colors: ReadonlyMap<string, GhosttyTheme> | null,
  edits: ThemeEditMap | null | undefined,
): ReadonlyMap<string, GhosttyTheme> | null {
  if (!colors || !edits || Object.keys(edits).length === 0) return colors;
  return new Map([...colors].map(([name, theme]) => [name, withEdits(theme, edits)]));
}
