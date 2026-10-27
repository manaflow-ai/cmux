// What the page leaves out on this Mac now (the host lists' `availability`, Swift
// `SettingsAvailability`): rows whose feature is off and choices this Mac cannot use, such as
// Energy Saver's row while its feature is off and its On Battery on a Mac with no battery. The schema
// keeps every row and choice; only the page's lists and editors read this.
import { useMemo } from "react";
import { useSettingsSelector } from "./context";
import type { HostLists } from "./ops";
import type { SchemaRow } from "./schema";

const NONE: readonly string[] = [];

/** Equal lists of keys or values, so a selector re-renders only when the host's lists change. */
export function sameList(a: readonly string[], b: readonly string[]): boolean {
  return a === b || (a.length === b.length && a.every((item, index) => item === b[index]));
}

/** The keys of the rows `host` hides now; empty before the host lists arrive. */
export function hiddenRowKeys(host: HostLists | null | undefined): ReadonlySet<string> {
  return new Set(host?.availability?.hidden_rows ?? NONE);
}

/** ``hiddenRowKeys`` of the page's host lists, as a component reads it: it renders again only when
 * the hidden keys change. */
export function useHiddenRows(): ReadonlySet<string> {
  const keys = useSettingsSelector((state) => state.host?.availability?.hidden_rows ?? NONE, sameList);
  return useMemo(() => new Set(keys), [keys]);
}

/** The values of `key`'s choices the host hides now; empty before the host lists arrive. */
export function useHiddenChoices(key: string): readonly string[] {
  return useSettingsSelector((state) => state.host?.availability?.hidden_choices?.[key] ?? NONE, sameList);
}

/**
 * `row` with the `hidden` choices left out; `value` (the current one) is always kept, so the editor
 * still shows what is selected. The same row object when nothing is hidden.
 */
export function withShownChoices(row: SchemaRow, hidden: readonly string[], value: unknown): SchemaRow {
  if (!row.choices || hidden.length === 0) return row;
  const choices = row.choices.filter((choice) => choice.value === value || !hidden.includes(choice.value));
  return choices.length === row.choices.length ? row : { ...row, choices };
}
