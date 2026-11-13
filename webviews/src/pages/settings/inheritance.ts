// What an unset row shows: the value it takes from somewhere else. A slider row's thumb and field
// sit on the effective value (never a schema placeholder that is not live), drawn as the row's own
// value: no source label and no dimming (Lucas 2026-11-11).
import { rowsByKey, type SchemaRow } from "./schema";
import type { SettingsState } from "./store";

/** `appearance.backgroundOpacity`: every surface's Opacity inherits it while unset. */
export const WINDOW_OPACITY_KEY = "appearance.backgroundOpacity";
const SURFACE_OPACITY = /^appearance\.surfaces\.[A-Za-z]+\.opacity$/;
const SURFACE_COLOR = /^appearance\.surfaces\.[A-Za-z]+\.color$/;

/** The row an unset row takes its value from, when it is another row (a surface's window value). */
export function parentKey(key: string): string | null {
  return SURFACE_OPACITY.test(key) ? WINDOW_OPACITY_KEY : null;
}

/** Whether `key` is a surface color, which shows the window's color while unset. */
export function inheritsWindowColor(key: string): boolean {
  return SURFACE_COLOR.test(key);
}

/** An unset number row's resting value. `known`: it is the live value (the parent's, or the one
 * the host derived), which the field and slider show as the row's value (Lucas 2026-11-11: "screw
 * placeholders, it should be the active value"); otherwise it is the schema placeholder, where the
 * thumb rests while the field keeps the default label. */
export type Effective = { value: number; known: boolean };

/**
 * The number an unset row rests on: the parent row's effective value (a surface's opacity is the
 * window's), else the value the host derived (the window opacity the theme or the art resolved, a
 * size at the live density), else the schema placeholder.
 */
export function effectiveNumber(state: SettingsState, row: SchemaRow, depth = 0): Effective | null {
  const range = row.range;
  if (!range) return null;
  const parent = depth < 2 ? parentKey(row.key) : null;
  if (parent) {
    const parentRow = state.rows.get(parent);
    const stored = typeof parentRow?.value === "number" ? parentRow.value : null;
    const value = stored ?? effectiveNumberOf(state, parent, depth + 1);
    if (value !== null) return { value, known: true };
  }
  const derived = state.host?.derived?.[row.key];
  if (typeof derived === "number") return { value: derived, known: true };
  return { value: range.placeholder, known: false };
}

/** `effectiveNumber` of the schema row `key`; null when it is no number row. */
function effectiveNumberOf(state: SettingsState, key: string, depth: number): number | null {
  const row = schemaRow(key);
  const effective = row ? effectiveNumber(state, row, depth) : null;
  return effective?.known ? effective.value : null;
}

function schemaRow(key: string): SchemaRow | undefined {
  return rowsByKey.get(key);
}
