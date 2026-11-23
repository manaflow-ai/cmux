// The last prompt index acpmux gave for a chat (direct.ts `readPromptIndex`), kept per chat so the
// next page draws the rail's every tick named and labeled on its first frame.
//
// Leo (2026-11-22, after a relaunch): "and then the scroll rail re-rednered. and then more shit
// re-rendered." The index is read only after the page's first paint (it scans every prompt), so a
// relaunch drew each older prompt's tick from the chat's count, unnamed, and named it a frame or two
// later: the rail drew again, every drawn tick's label changed. With this copy the first frame draws
// what the index will say; the index's answer replaces it only where it differs.
//
// Kept in memory, and in localStorage so a page reload or a relaunch keeps it: a few chats, each the
// index's columns. Read once per page; written in idle time after an answer that differs.

import { PromptHeads, type PromptHead } from "./promptHeads";

const STORAGE_KEY = "cmux.agentPane.promptIndex.v1";
/// Chats kept; the least recently used goes first.
const MAX_CHATS = 8;
/// A chat whose index text is longer than this is not kept (its rail draws from the count first, as
/// before): the copy stays a small part of the page's storage.
const MAX_TEXT = 256 * 1024;

type Stored = { sessionId: string; seqs: number[]; ats: number[]; texts: string[]; ids: string[] };

let chats: Map<string, PromptHeads> | undefined;
let saveQueued = false;

function storage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

function load(): Map<string, PromptHeads> {
  if (chats) return chats;
  chats = new Map();
  try {
    const raw = storage()?.getItem(STORAGE_KEY);
    const stored = raw ? (JSON.parse(raw) as Stored[]) : [];
    for (const chat of Array.isArray(stored) ? stored : []) {
      if (
        typeof chat?.sessionId !== "string" ||
        !Array.isArray(chat.seqs) ||
        !Array.isArray(chat.ats) ||
        !Array.isArray(chat.texts) ||
        !Array.isArray(chat.ids) ||
        chat.ats.length !== chat.seqs.length ||
        chat.texts.length !== chat.seqs.length ||
        chat.ids.length !== chat.seqs.length
      )
        continue;
      const heads: PromptHead[] = chat.seqs.map((seq, index) => ({
        seq: Number(seq),
        at: Number(chat.ats[index]),
        text: String(chat.texts[index] ?? ""),
        ...(chat.ids[index] ? { promptId: String(chat.ids[index]) } : {}),
      }));
      chats.set(chat.sessionId, PromptHeads.of(heads));
    }
  } catch {
    // A stored value from another build that does not parse is dropped; it is only a cache.
  }
  return chats;
}

function save() {
  saveQueued = false;
  const store = storage();
  if (!store || !chats) return;
  const out: Stored[] = [...chats].map(([sessionId, heads]) => {
    const list = Array.from({ length: heads.length }, (_, index) => PromptHeads.head(heads, index));
    return {
      sessionId,
      seqs: list.map((head) => head.seq),
      ats: list.map((head) => head.at),
      texts: list.map((head) => head.text),
      ids: list.map((head) => head.promptId ?? ""),
    };
  });
  try {
    store.setItem(STORAGE_KEY, JSON.stringify(out));
  } catch {
    // Full or refused storage keeps the in-memory copy only.
  }
}

function queueSave() {
  if (saveQueued) return;
  saveQueued = true;
  const idle = (globalThis as { requestIdleCallback?: (run: () => void, options?: { timeout: number }) => unknown })
    .requestIdleCallback;
  if (idle) idle(save, { timeout: 2_000 });
  else setTimeout(save, 0);
}

/// The index last kept for `sessionId`, if any.
export function keptPromptIndex(sessionId: string | undefined): PromptHeads | undefined {
  if (!sessionId) return undefined;
  const all = load();
  const heads = all.get(sessionId);
  if (!heads) return undefined;
  all.delete(sessionId);
  all.set(sessionId, heads);
  return heads;
}

/// Whether `kept`, cut at `before`, names the same prompts as `fresh` (an index read before `before`).
export function samePromptIndex(kept: PromptHeads, fresh: PromptHeads, before: number): boolean {
  const cut = PromptHeads.before(kept, before);
  if (cut.length !== fresh.length) return false;
  for (let index = 0; index < cut.length; index += 1) {
    if (cut.seqs[index] !== fresh.seqs[index] || cut.ats[index] !== fresh.ats[index]) return false;
    if (PromptHeads.text(cut, index) !== PromptHeads.text(fresh, index)) return false;
    if (PromptHeads.promptId(cut, index) !== PromptHeads.promptId(fresh, index)) return false;
  }
  return true;
}

/// Keeps acpmux's answer for `sessionId`, written in idle time.
export function keepPromptIndex(sessionId: string, heads: PromptHeads): void {
  const all = load();
  all.delete(sessionId);
  if (heads.length === 0 || heads.texts.length > MAX_TEXT) {
    queueSave();
    return;
  }
  all.set(sessionId, heads);
  while (all.size > MAX_CHATS) all.delete(all.keys().next().value!);
  queueSave();
}

/// Tests: forget everything, memory and storage.
export function resetKeptPromptIndex(): void {
  chats = new Map();
  try {
    storage()?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing kept.
  }
}
