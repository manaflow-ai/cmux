// The daemon's durable settings history (settings-history-v1, cmux-config history.rs) as the
// Settings page reads it through its host: every published change of the settings file, by any
// writer (this page, the palette, the CLI, MCP agents, a hand edit). The page never reaches the
// daemon's settings.* operations itself (page_access.rs); the host forwards cmux.settings.history,
// .undo, .restore and .reset_group with the person's origin. Pure, so the bar's choices are
// tested without a page.
import type { HistoryEntry } from "./appearanceHistory";
import { UNTRACKED_KEYS } from "./appearanceUndo";
import { type SchemaRow, schema } from "./schema";

/** One recorded change, newest first in a read. `undoes`: the revision a settings.undo took back. */
export type DurableEntry = { revision: number; at: number; origin: string; keys: string[]; undoes: number | null };

function decimal(value: unknown): number | null {
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : null;
}

/** A `settings.history` reply's entries (newest first); an entry that does not read is left out. */
export function parseDurableHistory(reply: unknown): DurableEntry[] {
  const entries = (reply as { entries?: unknown } | null)?.entries;
  if (!Array.isArray(entries)) return [];
  return entries.flatMap((raw): DurableEntry[] => {
    const item = raw as Record<string, unknown> | null;
    const revision = decimal(item?.revision);
    const at = decimal(item?.at);
    if (revision === null || at === null || typeof item?.origin !== "string") return [];
    const keys = Array.isArray(item.keys) ? item.keys.filter((key): key is string => typeof key === "string") : [];
    return [
      { revision, at, origin: item.origin, keys, undoes: item.undoes === undefined ? null : decimal(item.undoes) },
    ];
  });
}

/** The newest revision in a read, 0 for none. */
export function newestRevision(entries: readonly DurableEntry[] | null): number {
  return entries?.[0]?.revision ?? 0;
}

/** What settings.undo would take back (cmux-config `history::undo_pick`): the newest change that is
 * no undo and was not undone yet. The daemon also passes over a change whose earlier text is the
 * file's text now, which the page cannot see; the daemon decides on the click, this only names it. */
export function nextDurableUndo(entries: readonly DurableEntry[]): DurableEntry | null {
  const undone = new Set(entries.flatMap((entry) => (entry.undoes === null ? [] : [entry.undoes])));
  return entries.find((entry) => entry.undoes === null && !undone.has(entry.revision)) ?? null;
}

/** A change of bookkeeping only (what each background mode last showed, the backgrounds shown
 * before): no look of its own, so it is no step. The page writes it beside a background change and
 * again when an undo leaves a mode; the bar passes over it, and an undo takes it back on the way. */
export function isBookkeeping(entry: DurableEntry): boolean {
  return entry.keys.length > 0 && entry.keys.every((key) => UNTRACKED_KEYS.has(key));
}

/** The newest revision that is a look's change (bookkeeping passed over), 0 for none. */
export function newestLookRevision(entries: readonly DurableEntry[] | null): number {
  return entries?.find((entry) => !isBookkeeping(entry))?.revision ?? 0;
}

/** What the bar's Undo takes back: the newest change settings.undo would reach that is a look's,
 * passing over bookkeeping it takes back first. */
export function nextLookUndo(entries: readonly DurableEntry[]): DurableEntry | null {
  const undone = new Set(entries.flatMap((entry) => (entry.undoes === null ? [] : [entry.undoes])));
  return entries.find((entry) => entry.undoes === null && !undone.has(entry.revision) && !isBookkeeping(entry)) ?? null;
}

/** What the bar's Undo does now: `step`, the page's own step through settings.undo; `foreign`, a newer
 * change by another writer (or one from before this visit) through settings.undo; `memory`, the page's
 * own stack (a step the file does not hold, such as a workspace background, or a host without the
 * durable history); null, nothing to undo. */
export type UndoPlan = { kind: "step" } | { kind: "foreign"; pick: DurableEntry } | { kind: "memory" } | null;

export function planUndo(top: HistoryEntry | null, entries: readonly DurableEntry[] | null): UndoPlan {
  if (entries === null) return top ? { kind: "memory" } : null;
  const pick = nextLookUndo(entries);
  if (top && pick && top.revisions?.includes(pick.revision)) return { kind: "step" };
  if (pick && (!top || pick.revision > (top.head ?? 0))) return { kind: "foreign", pick };
  return top ? { kind: "memory" } : null;
}

/** Whether a change was the person's own (the app's writes, a declared `--origin user`). */
export function isPersonOrigin(origin: string): boolean {
  return origin === "app" || origin === "user";
}

/** A row's group as settings.reset_group names it (cmux-config `Row::group_id`): its section and
 * the last part of its group's localization key, or the group's title in lowercase letters and
 * digits when it has no key. */
export function rowGroupId(row: SchemaRow): string {
  const slug = row.group.key
    ? row.group.key.split(".").at(-1)!
    : row.group.text.replace(/[^A-Za-z0-9]/g, "").toLowerCase();
  return `${row.section}.${slug}`;
}

/** The rows settings.reset_group resets for `name` (cmux-config `Schema::rows_in_group`): every row
 * of a section, or of one group in it. */
export function rowsInGroup(name: string): SchemaRow[] {
  return schema.rows.filter((row) => row.section === name || rowGroupId(row) === name);
}

/** The settings.reset_group name that resets exactly a card's keys, or null when no group is the
 * card (the page's layout regroups rows, moves look rows in, or adds a key no row draws): such a
 * card resets its keys in one edit instead. Either way the reset is one history entry. */
export function areaResetGroup(area: { keys: readonly string[] }): string | null {
  const first = schema.rows.find((row) => row.key === area.keys[0]);
  if (!first) return null;
  const group = rowGroupId(first);
  const groupKeys = new Set(rowsInGroup(group).map((row) => row.key));
  const keys = new Set(area.keys);
  if (groupKeys.size !== keys.size) return null;
  for (const key of keys) if (!groupKeys.has(key)) return null;
  return group;
}
