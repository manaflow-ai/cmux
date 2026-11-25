// The rows of the theme picker (ThemePicker): the null choice ("Use Ghostty Config", or "Match
// Terminal Theme" for the app theme) first, then the starred themes (appearance.favoriteThemes) as
// their own group, then every bundled theme whose name has the typed text. Kept apart from the
// component so the search and the starred group are tested without a DOM.

/** The row value of the null choice; no theme name can start with a NUL. */
export const CONFIG_ROW = "\u0000config";
/** The prefix of a starred group row: the same theme appears again under all themes, and every row
 * value must be unique. No theme name starts with SOH. */
const STARRED_ROW = "\u0001starred:";

export type PickerRowsInput = {
  names: readonly string[];
  query: string;
  /** Whether the list has the null choice (the light and dark sides of the app theme have none). */
  nullChoice: boolean;
  /** The starred theme names (appearance.favoriteThemes); listed first, in the order they were starred. */
  favorites?: readonly string[];
};

/** Case-insensitive substring match on the trimmed query; an empty query matches every name. */
export function matchesQuery(name: string, query: string): boolean {
  const typed = query.trim().toLowerCase();
  return typed === "" || name.toLowerCase().includes(typed);
}

/** The picker's rows in order. The null choice shows only while nothing is typed; the starred group
 * holds the starred themes that match, then every matching theme follows. */
export function pickerRows({ names, query, nullChoice, favorites = [] }: PickerRowsInput): string[] {
  const matched = names.filter((name) => matchesQuery(name, query));
  // The order they were starred, as launch rotation turns through them; a star with no theme drops.
  const shown = new Set(matched);
  const group = [...new Set(favorites)].filter((name) => shown.has(name)).map((name) => STARRED_ROW + name);
  const rows = [...group, ...matched];
  return nullChoice && query.trim() === "" ? [CONFIG_ROW, ...rows] : rows;
}

/** Whether a row is in the starred group. */
export function isStarredRow(row: string): boolean {
  return row.startsWith(STARRED_ROW);
}

/** The theme name a row picks (the null choice's value is CONFIG_ROW itself). */
export function rowTheme(row: string): string {
  return isStarredRow(row) ? row.slice(STARRED_ROW.length) : row;
}

/** The heading a row starts, if any: "starred" before the starred group, "all" before the first
 * other theme when there is a starred group above it. */
export function rowGroupStart(rows: readonly string[], index: number): "starred" | "all" | null {
  const row = rows[index];
  if (row === undefined || row === CONFIG_ROW) return null;
  const previous = index > 0 ? rows[index - 1] : undefined;
  if (isStarredRow(row)) return previous !== undefined && isStarredRow(previous) ? null : "starred";
  return previous !== undefined && isStarredRow(previous) ? "all" : null;
}

/** appearance.favoriteThemes with `name` starred or unstarred: a new star goes last. */
export function toggledFavorites(favorites: readonly string[], name: string): string[] {
  return favorites.includes(name) ? favorites.filter((item) => item !== name) : [...favorites, name];
}
