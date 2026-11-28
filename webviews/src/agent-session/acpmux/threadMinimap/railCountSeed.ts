// How far a chat's summary count (`turnCount`, the snapshot's `promptCount`) is from the rows its rail
// draws once the prompt index has named them, so the next open's first frame lays out the final rows.
//
// The summary counts turns: a carried turn, a watched or adopted one counts with no prompt of its own,
// and the index (acpmux `prompt_index`) names only the person's prompts. A chat whose two differ drew
// its rail from the count on the first frame after a restart, then moved every tick and the band by the
// difference when the index answered, seconds later, once acpmux was back (Leo, 2026-11-25: "and then
// the scroll rail re-rednered"). The rail learns the difference each time the index replaces the count
// and keeps it here, in memory and in localStorage, so a restart keeps it too.
//
// A few hundred chats, a number each: a chat not kept draws from the count, as it did before.
const STORAGE_KEY = "cmux.agentPane.railCountOffset.v1";
/// The chats kept, most recently learned last.
const MAX_CHATS = 256;

let offsets: Map<string, number> | undefined;

function storage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

function load(): Map<string, number> {
  if (offsets) return offsets;
  offsets = new Map();
  try {
    const raw = storage()?.getItem(STORAGE_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : undefined;
    if (Array.isArray(parsed))
      for (const entry of parsed) {
        if (!Array.isArray(entry)) continue;
        const [sessionId, offset] = entry as unknown[];
        if (typeof sessionId === "string" && typeof offset === "number" && Number.isInteger(offset))
          offsets.set(sessionId, offset);
      }
  } catch {
    // An unreadable entry is no offset: the rail draws from the count.
  }
  return offsets;
}

function save(all: Map<string, number>): void {
  try {
    storage()?.setItem(STORAGE_KEY, JSON.stringify([...all]));
  } catch {
    // A full or refused store keeps the offset for this page only.
  }
}

/// The rail's row count for a chat whose summary counts `count`: the count less what it was over by
/// when the index last answered. Undefined stays undefined (no count to seed).
export function seededPromptCount(sessionId: string | undefined, count: number | undefined): number | undefined {
  if (count === undefined || !sessionId) return count;
  const offset = load().get(sessionId);
  return offset === undefined ? count : Math.max(0, count - offset);
}

/// Keeps how far `count` (the summary's, as drawn while the index was out) was from `rows` (the rail's
/// rows once the index named them).
export function learnPromptCount(sessionId: string | undefined, count: number, rows: number): void {
  if (!sessionId || !Number.isFinite(count) || !Number.isFinite(rows)) return;
  const offset = Math.round(count - rows);
  const all = load();
  if (all.get(sessionId) === offset) return;
  all.delete(sessionId);
  all.set(sessionId, offset);
  while (all.size > MAX_CHATS) all.delete(all.keys().next().value!);
  save(all);
}

export function resetPromptCountSeedsForTests(): void {
  offsets = undefined;
  try {
    storage()?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing kept.
  }
}
