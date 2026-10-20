// The rows of the theme picker (ThemePicker): the null choice ("Use Ghostty Config", or "Match
// Terminal Theme" for the app theme) first, then every bundled theme whose name has the typed text.
// Kept apart from the component so the search is tested without a DOM.

/** The row value of the null choice; no theme name can start with a NUL. */
export const CONFIG_ROW = "\u0000config";

export type PickerRowsInput = {
  names: readonly string[];
  query: string;
  /** Whether the list has the null choice (the light and dark sides of the app theme have none). */
  nullChoice: boolean;
};

/** Case-insensitive substring match on the trimmed query; an empty query matches every name. */
export function matchesQuery(name: string, query: string): boolean {
  const typed = query.trim().toLowerCase();
  return typed === "" || name.toLowerCase().includes(typed);
}

/** The picker's rows in order. The null choice shows only while nothing is typed. */
export function pickerRows({ names, query, nullChoice }: PickerRowsInput): string[] {
  const matched = names.filter((name) => matchesQuery(name, query));
  return nullChoice && query.trim() === "" ? [CONFIG_ROW, ...matched] : matched;
}
