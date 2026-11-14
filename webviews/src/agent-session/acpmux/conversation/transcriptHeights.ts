// The measured place of each prompt in a chat seen whole, kept per chat and width, so the room held
// for older history (olderReserve.ts) is exact the next time the chat opens on its tail, instead of
// an estimate from the turns loaded so far.
//
// Leo (2026-11-11): "the thumb turns from a tiny thing that would imply a big chat to just a medium
// sized thumb at the top". The room is a guess while older pages have not loaded; once the reader has
// been to the top, the chat's real height above every prompt is known. A prompt's place from the
// chat's start is what the room above it is when it is the first loaded prompt.
//
// Kept in memory, and in localStorage so a page reload (a web update) keeps it: a few chats, each a
// list of prompt ids and their tops. Read once per chat; written in idle time after the chat was
// placed whole.

const STORAGE_KEY = "cmux.agentPane.promptTops.v1";
/// Chats kept; the least recently used goes first.
const MAX_CHATS = 8;
/// Prompts kept per chat: past this the oldest are left out (their rooms are estimated as before).
const MAX_PROMPTS = 4000;

type Entry = { width: number; tops: Map<string, number> };
type Stored = { sessionId: string; width: number; ids: string[]; tops: number[] };

let chats: Map<string, Entry> | undefined;

function storage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

function load(): Map<string, Entry> {
  if (chats) return chats;
  chats = new Map();
  try {
    const raw = storage()?.getItem(STORAGE_KEY);
    const stored = raw ? (JSON.parse(raw) as Stored[]) : [];
    for (const chat of Array.isArray(stored) ? stored : []) {
      if (typeof chat?.sessionId !== "string" || !Array.isArray(chat.ids) || !Array.isArray(chat.tops)) continue;
      const tops = new Map<string, number>();
      chat.ids.forEach((id, index) => {
        const top = chat.tops[index];
        if (typeof id === "string" && typeof top === "number" && Number.isFinite(top)) tops.set(id, top);
      });
      chats.set(chat.sessionId, { width: chat.width, tops });
    }
  } catch {
    // A stored value from another build that does not parse is dropped; it is only a cache.
  }
  return chats;
}

function save() {
  const store = storage();
  if (!store || !chats) return;
  const out: Stored[] = [...chats].map(([sessionId, { width, tops }]) => ({
    sessionId,
    width,
    ids: [...tops.keys()],
    tops: [...tops.values()].map((top) => Math.round(top)),
  }));
  try {
    store.setItem(STORAGE_KEY, JSON.stringify(out));
  } catch {
    // Full or refused storage keeps the in-memory copy only.
  }
}

/// A prompt's top from the chat's start, from when the chat was last held whole at `width`.
export function knownPromptTop(sessionId: string | undefined, width: number, rowId: string): number | undefined {
  if (!sessionId) return undefined;
  const entry = load().get(sessionId);
  if (!entry || Math.abs(entry.width - width) > 0.5) return undefined;
  return entry.tops.get(rowId);
}

/// Whether `sessionId` has places at `width` (a cheap check before a scan of the rows).
export function hasPromptTops(sessionId: string | undefined, width: number): boolean {
  const entry = sessionId ? load().get(sessionId) : undefined;
  return !!entry && Math.abs(entry.width - width) <= 0.5;
}

/// Keeps the tops of a chat held whole (no older history left), at `width`. `prompts` lists each
/// prompt's id and its top from the chat's start, oldest first.
export function keepPromptTops(
  sessionId: string | undefined,
  width: number,
  prompts: readonly { id: string; top: number }[],
): void {
  if (!sessionId || prompts.length === 0) return;
  const all = load();
  const kept = prompts.length > MAX_PROMPTS ? prompts.slice(prompts.length - MAX_PROMPTS) : prompts;
  const previous = all.get(sessionId);
  if (
    previous &&
    Math.abs(previous.width - width) <= 0.5 &&
    previous.tops.size === kept.length &&
    kept.every((prompt) => Math.abs((previous.tops.get(prompt.id) ?? Number.NaN) - prompt.top) < 1)
  )
    return;
  all.delete(sessionId);
  all.set(sessionId, { width, tops: new Map(kept.map((prompt) => [prompt.id, prompt.top])) });
  while (all.size > MAX_CHATS) all.delete(all.keys().next().value!);
  save();
}

/// Tests: forget everything, memory and storage.
export function resetPromptTops(): void {
  chats = new Map();
  try {
    storage()?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing kept.
  }
}
