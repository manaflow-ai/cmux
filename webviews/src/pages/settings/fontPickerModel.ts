// The rows of a font family picker (FontPicker): the default ("Ghostty Config", "Terminal Font")
// first, then the fonts picked lately, then every other installed family whose name has the typed
// text. Recent fonts are the host's list (ready().domains.recent_fonts, newest first; the palette's
// Change Font… shares it), so switching back and forth is one step. Kept apart from the component
// so the order is tested without a DOM.
import { matchesQuery } from "./themePickerModel";

/** The row value of the default choice; no family name can start with a NUL. */
export const DEFAULT_FONT_ROW = "\u0000default";

/** How many recent fonts the list shows (the host keeps the same number). */
export const RECENT_FONT_LIMIT = 6;

export type FontRowsInput = {
  names: readonly string[];
  recent: readonly string[];
  query: string;
};

export type FontRows = {
  rows: string[];
  /** The rows listed as recent: they show the Recent tag. */
  recent: ReadonlySet<string>;
};

/** The picker's rows in order. Recent fonts no longer installed are left out; the default shows
 * only while nothing is typed. */
export function fontRows({ names, recent, query }: FontRowsInput): FontRows {
  const installed = new Set(names);
  const recentShown = recent.filter((name) => installed.has(name)).slice(0, RECENT_FONT_LIMIT);
  const recentSet = new Set(recentShown);
  const matched = (list: readonly string[]) => list.filter((name) => matchesQuery(name, query));
  const rest = names.filter((name) => !recentSet.has(name));
  const lead = query.trim() === "" ? [DEFAULT_FONT_ROW] : [];
  return { rows: [...lead, ...matched(recentShown), ...matched(rest)], recent: recentSet };
}

/** `recent` after picking `name`: it moves to the front, the list keeps its limit. */
export function recentAfterPick(recent: readonly string[], name: string): string[] {
  return [name, ...recent.filter((other) => other !== name)].slice(0, RECENT_FONT_LIMIT);
}

/** The CSS font stack that draws `name` in its own face (a fixed-pitch fallback). */
export function fontFace(name: string): string {
  return `"${name.replace(/["\\]/g, "")}", monospace`;
}
