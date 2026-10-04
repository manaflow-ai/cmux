// Recent and frequent icons (frecency) and the remembered skin tone. The picker reads and writes
// one small `PickerPrefs` record through `PickerPrefsStore`; the host decides where it lives
// (the app's personal state, so every window shares it). Pure functions, unit tested.
import type { SkinTone } from "./emojiData";

export interface RecentEntry {
  /** iconKey() of the icon, base (untoned) form for emoji. */
  readonly key: string;
  readonly count: number;
  /** Milliseconds since the epoch of the last use. */
  readonly last: number;
}

export interface PickerPrefs {
  readonly tone: SkinTone;
  readonly recents: readonly RecentEntry[];
}

export interface PickerPrefsStore {
  load(): PickerPrefs | Promise<PickerPrefs>;
  save(prefs: PickerPrefs): void;
}

export const EMPTY_PREFS: PickerPrefs = { tone: 0, recents: [] };
export const MAX_RECENTS = 36;
const HALF_LIFE_MS = 7 * 24 * 3600 * 1000;

/** Use count decayed by age: one use today outranks three uses a month ago. */
export function frecency(entry: RecentEntry, now: number): number {
  const age = Math.max(0, now - entry.last);
  return entry.count * 0.5 ** (age / HALF_LIFE_MS);
}

export function recordUse(prefs: PickerPrefs, key: string, now: number): PickerPrefs {
  const existing = prefs.recents.find((entry) => entry.key === key);
  const updated: RecentEntry = { key, count: (existing?.count ?? 0) + 1, last: now };
  const rest = prefs.recents.filter((entry) => entry.key !== key);
  const recents = [updated, ...rest].sort((a, b) => frecency(b, now) - frecency(a, now)).slice(0, MAX_RECENTS);
  return { ...prefs, recents };
}

/** Keys best first. */
export function rankedKeys(prefs: PickerPrefs, now: number): string[] {
  return [...prefs.recents].sort((a, b) => frecency(b, now) - frecency(a, now)).map((entry) => entry.key);
}

/** A search tie-breaker: a small bonus (at most 9, below one match tier) for recent keys. */
export function searchBoost(
  prefs: PickerPrefs,
  indexOfKey: (key: string) => number | undefined,
  now: number,
): Map<number, number> {
  const boost = new Map<number, number>();
  const keys = rankedKeys(prefs, now);
  keys.forEach((key, rank) => {
    const index = indexOfKey(key);
    if (index !== undefined) boost.set(index, Math.max(1, 9 - rank));
  });
  return boost;
}

export function decodePrefs(value: unknown): PickerPrefs {
  if (!value || typeof value !== "object") return EMPTY_PREFS;
  const raw = value as { tone?: unknown; recents?: unknown };
  const tone = typeof raw.tone === "number" && raw.tone >= 0 && raw.tone <= 5 ? (Math.floor(raw.tone) as SkinTone) : 0;
  const recents = Array.isArray(raw.recents)
    ? raw.recents
        .filter(
          (entry): entry is RecentEntry =>
            !!entry &&
            typeof entry.key === "string" &&
            entry.key.length <= 200 &&
            typeof entry.count === "number" &&
            typeof entry.last === "number",
        )
        .slice(0, MAX_RECENTS)
    : [];
  return { tone, recents };
}
