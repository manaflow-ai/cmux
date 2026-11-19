// Pure presentation model of the Keyboard Shortcuts page: sort, search, key filters, conflict
// filter, selection and the Reset rule. The provider owns the table and the conflict facts.
import type { Binding, BindingSource } from "./types";

/** A filter on the keys: rows whose strokes start with (or equal) these strokes. */
export interface KeyFilter {
  key: string;
  exact: boolean;
}

export interface BindingQuery {
  text: string;
  /** Set by recording or by a conflict marker; it replaces the text match. */
  keyFilter?: KeyFilter;
  conflictsOnly: boolean;
}

export const SourceLabel: Record<BindingSource | "removed" | "removedByGhostty", string> = {
  default: "keybindings.page.source.default",
  app: "keybindings.page.source.app",
  user: "keybindings.page.source.user",
  removed: "keybindings.page.source.removed",
  removedByGhostty: "keybindings.page.source.removedByGhostty",
  ghostty: "keybindings.page.source.ghostty",
  "ghostty-fallback": "keybindings.page.source.ghosttyDefault",
};

/** A row the page cannot change or remove: a removed default, or a Ghostty keybind (cmux never
 *  writes the Ghostty config; the user edits that file). */
export function isReadOnly(binding: Pick<Binding, "source" | "removed">): boolean {
  return binding.removed === true || binding.source === "ghostty" || binding.source === "ghostty-fallback";
}

/** A row the `when` editor can change: one with keys (an unset row has nothing to scope). */
export function canEditWhen(binding: Pick<Binding, "source" | "removed" | "unset">): boolean {
  return !isReadOnly(binding) && binding.unset !== true;
}

/** One keycap per modifier and one for the key ("⌃⌥↑" -> ⌃ ⌥ ↑), for the recorder's large caps. */
export function strokeCaps(stroke: string): string[] {
  const mods = stroke.match(/^[⌃⌥⇧⌘]*/)?.[0] ?? "";
  const key = stroke.slice(mods.length);
  return [...mods.split(""), ...(key ? [key] : [])];
}

/** A row's identity across re-lists (ids are positions and move when the table changes). */
export function identity(binding: Pick<Binding, "source" | "command" | "key" | "when" | "removed">): string {
  return [binding.removed ? "removed" : binding.source, binding.command, binding.key, binding.when ?? ""].join(
    "\u0000",
  );
}

/** The strokes of a key text, normalized: lower case, one space between strokes. */
export function strokes(key: string): string[] {
  return key.trim().toLowerCase().split(/\s+/).filter(Boolean);
}

/** The strokes of a display text, one keycap chip each. */
export function displayStrokes(display: string): string[] {
  return display.trim().split(/\s+/).filter(Boolean);
}

/** Whether `key` starts with every stroke of `prefix` (whole strokes; equal when `exact`). */
export function keyMatches(key: string, filter: KeyFilter): boolean {
  const have = strokes(key);
  const want = strokes(filter.key);
  if (want.length === 0) return true;
  if (filter.exact ? have.length !== want.length : have.length < want.length) return false;
  return want.every((stroke, index) => have[index] === stroke);
}

/** Case-insensitive match on title, command id, key text or display. */
export function textMatches(binding: Binding, text: string): boolean {
  const needle = text.trim().toLowerCase();
  if (!needle) return true;
  return [binding.title, binding.command, binding.key, binding.display].some((field) =>
    field.toLowerCase().includes(needle),
  );
}

/** By title, then key; the id breaks ties so the order is stable. */
export function sortBindings(bindings: readonly Binding[]): Binding[] {
  return [...bindings].sort(
    (a, b) =>
      a.title.localeCompare(b.title, undefined, { sensitivity: "base" }) || a.key.localeCompare(b.key) || a.id - b.id,
  );
}

export function filterBindings(bindings: readonly Binding[], query: BindingQuery): Binding[] {
  // A default the user replaced is not shown while its action has keys (or is unset): the new
  // keys' row carries Reset, which brings the default back.
  const keyed = new Set(bindings.filter((binding) => !binding.removed).map((binding) => binding.command));
  return bindings.filter((binding) => {
    if (binding.removed && keyed.has(binding.command)) return false;
    if (query.conflictsOnly && (binding.removed || binding.conflicts.length === 0)) return false;
    if (query.keyFilter) return keyMatches(binding.key, query.keyFilter);
    return textMatches(binding, query.text);
  });
}

/** The Source column's label key: a removed default says who removed it. */
export function sourceLabel(binding: Pick<Binding, "source" | "removed" | "removedBy">): string {
  if (!binding.removed) return SourceLabel[binding.source];
  return SourceLabel[binding.removedBy === "ghostty" ? "removedByGhostty" : "removed"];
}

/** Reset applies when the command has a user entry or a default a cmux removal took out (a key the
 *  Ghostty config claims comes back only from the Ghostty config). */
export function resettableCommands(bindings: readonly Binding[]): Set<string> {
  const out = new Set<string>();
  for (const binding of bindings) {
    if (binding.source === "user" || (binding.removed && binding.removedBy !== "ghostty")) out.add(binding.command);
  }
  return out;
}

/** The shown rows with each one's identity and place: built once per query or re-read, so a
 *  selection, a key press or a scroll finds its row without a pass over the table. */
export interface RowList {
  rows: readonly Binding[];
  ids: readonly string[];
  /** Row identity to its index in `rows`. */
  index: ReadonlyMap<string, number>;
}

export function rowList(rows: readonly Binding[]): RowList {
  const ids = rows.map(identity);
  return { rows, ids, index: new Map(ids.map((id, at) => [id, at])) };
}

/** The index of `id`'s row, or -1 when it is not shown. */
export function rowIndex(list: RowList, id: string | undefined): number {
  return id === undefined ? -1 : (list.index.get(id) ?? -1);
}

/** The next row identity for Up/Down; from no selection, Down picks the first and Up the last. */
export function moveSelection(list: RowList, selection: string | undefined, offset: number): string | undefined {
  const { ids } = list;
  if (!ids.length) return selection;
  let index = rowIndex(list, selection);
  if (index < 0) index = offset > 0 ? -1 : ids.length;
  return ids[Math.max(0, Math.min(ids.length - 1, index + offset))];
}

/**
 * The re-read table, each entry that did not change kept as the object the page already holds: a
 * re-read sends the whole table, and a memoized row draws again only for the entry that changed.
 */
export function keepUnchanged(previous: readonly Binding[], next: readonly Binding[]): Binding[] {
  if (!previous.length) return [...next];
  const held = new Map(previous.map((binding) => [`${binding.id}\u0000${identity(binding)}`, binding]));
  return next.map((binding) => {
    const old = held.get(`${binding.id}\u0000${identity(binding)}`);
    return old && sameBinding(old, binding) ? old : binding;
  });
}

function sameBinding(a: Binding, b: Binding): boolean {
  const keys = Object.keys(a) as (keyof Binding)[];
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => {
    const x = a[key];
    const y = b[key];
    if (x === y) return true;
    if (Array.isArray(x) && Array.isArray(y)) return x.length === y.length && x.every((item, at) => item === y[at]);
    // `args` (a plain JSON object from the wire).
    return typeof x === "object" && typeof y === "object" && JSON.stringify(x) === JSON.stringify(y);
  });
}

/** Keeps a selection whose row is still shown; else nothing is selected. */
export function reconcileSelection(rows: readonly Binding[], selection: string | undefined): string | undefined {
  return selection !== undefined && rows.some((row) => identity(row) === selection) ? selection : undefined;
}

/** A `when` text from the inline editor: blank means no condition. */
export function normalizeWhen(text: string): string | null {
  const trimmed = text.trim();
  return trimmed ? trimmed : null;
}
