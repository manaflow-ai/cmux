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

export const SourceLabel: Record<BindingSource | "removed", string> = {
  default: "keybindings.page.source.default",
  app: "keybindings.page.source.app",
  user: "keybindings.page.source.user",
  removed: "keybindings.page.source.removed",
};

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
  return bindings.filter((binding) => {
    if (query.conflictsOnly && (binding.removed || binding.conflicts.length === 0)) return false;
    if (query.keyFilter) return keyMatches(binding.key, query.keyFilter);
    return textMatches(binding, query.text);
  });
}

/** Reset applies when the command has a user entry or a removed default. */
export function resettableCommands(bindings: readonly Binding[]): Set<string> {
  const out = new Set<string>();
  for (const binding of bindings) if (binding.source === "user" || binding.removed) out.add(binding.command);
  return out;
}

/** The next row identity for Up/Down; from no selection, Down picks the first and Up the last. */
export function moveSelection(
  rows: readonly Binding[],
  selection: string | undefined,
  offset: number,
): string | undefined {
  if (!rows.length) return selection;
  let index = rows.findIndex((row) => identity(row) === selection);
  if (index < 0) index = offset > 0 ? -1 : rows.length;
  return identity(rows[Math.max(0, Math.min(rows.length - 1, index + offset))]);
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
