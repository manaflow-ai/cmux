// Stash: the composer's draft put aside with one key (⌃S), the prompt emptied for something else,
// and the draft brought back (⌃S on an empty prompt, or a pick from the Stashed chip's list). Each
// chat holds a short stack, newest first. The page keeps the stacks and mirrors them to localStorage
// so a reload or a released page keeps them; an entry's attachments go there only while the entry
// stays small, otherwise the stored copy keeps its text and the page's copy keeps its chips.
import { useSyncExternalStore } from "react";
import { withoutInlineTokens, type ComposerAttachment } from "../attachments";

export type StashedDraft = {
  id: string;
  text: string;
  attachments: ComposerAttachment[];
  at: number;
};

/// The most drafts one chat holds; a stash past it lets the oldest go.
export const STASH_LIMIT = 5;
/// The most chats whose stacks are kept; the stack used longest ago goes first.
export const STASH_CHATS = 50;
/// An entry stored with its attachments only below this many characters of JSON.
const STORED_ENTRY_MAX = 256 * 1024;
export const STORAGE_KEY = "cmux.agentPane.draftStash.v1";

type Stacks = ReadonlyMap<string, readonly StashedDraft[]>;

const NONE: readonly StashedDraft[] = [];
let stacks: Stacks = new Map();
let loaded = false;
const listeners = new Set<() => void>();
const emit = () => {
  for (const listener of listeners) listener();
};

const storage = (): Storage | undefined => {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
};

/// The stacks kept from an earlier page, malformed entries left out.
export function parseStacks(raw: string | null | undefined): Map<string, StashedDraft[]> {
  const out = new Map<string, StashedDraft[]>();
  if (!raw) return out;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return out;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return out;
  for (const [chat, list] of Object.entries(parsed as Record<string, unknown>)) {
    if (!Array.isArray(list)) continue;
    const drafts = list
      .filter(
        (entry): entry is StashedDraft =>
          !!entry &&
          typeof entry === "object" &&
          typeof entry.id === "string" &&
          typeof entry.text === "string" &&
          typeof entry.at === "number",
      )
      .map((entry) => ({ ...entry, attachments: Array.isArray(entry.attachments) ? entry.attachments : [] }))
      .slice(0, STASH_LIMIT);
    if (drafts.length) out.set(chat, drafts);
  }
  return out;
}

/// What localStorage keeps of `stacks`: a large entry without its attachments (their places in the
/// text stay; the page that stashed it still has them).
export function storedStacks(all: Stacks): string {
  const out: Record<string, StashedDraft[]> = {};
  for (const [chat, list] of all)
    out[chat] = list.map((entry) =>
      entry.attachments.length && JSON.stringify(entry).length > STORED_ENTRY_MAX ? { ...entry, attachments: [] } : entry,
    );
  return JSON.stringify(out);
}

function load(): void {
  if (loaded) return;
  loaded = true;
  stacks = parseStacks(storage()?.getItem(STORAGE_KEY));
}

function save(next: Map<string, readonly StashedDraft[]>): void {
  // The stacks used longest ago go once there are too many chats.
  while (next.size > STASH_CHATS) next.delete(next.keys().next().value!);
  stacks = next;
  try {
    storage()?.setItem(STORAGE_KEY, storedStacks(next));
  } catch {
    // Full or unavailable: the page's copy still holds them.
  }
  emit();
}

let serial = 0;

/// Puts `draft` on top of `chat`'s stack. Nothing is stashed for an empty draft.
export function stashDraft(chat: string, text: string, attachments: readonly ComposerAttachment[]): boolean {
  if (!text.trim() && attachments.length === 0) return false;
  load();
  const entry: StashedDraft = {
    id: `stash-${Date.now().toString(36)}-${(serial++).toString(36)}`,
    text,
    attachments: [...attachments],
    at: Date.now(),
  };
  const next = new Map(stacks);
  const list = [entry, ...(next.get(chat) ?? NONE)].slice(0, STASH_LIMIT);
  // Most recently used last, so the oldest key is the one to let go.
  next.delete(chat);
  next.set(chat, list);
  save(next);
  return true;
}

/// Takes the draft `id` (else the newest) off `chat`'s stack, or undefined when there is none.
export function takeStashed(chat: string, id?: string): StashedDraft | undefined {
  load();
  const list = stacks.get(chat) ?? NONE;
  const entry = id === undefined ? list[0] : list.find((candidate) => candidate.id === id);
  if (!entry) return undefined;
  const next = new Map(stacks);
  const rest = list.filter((candidate) => candidate !== entry);
  if (rest.length) next.set(chat, rest);
  else next.delete(chat);
  save(next);
  return entry;
}

/// Drops the draft `id` from `chat`'s stack.
export function dropStashed(chat: string, id: string): void {
  void takeStashed(chat, id);
}

/// A new chat's stack follows it once it has a session.
export function moveStash(from: string, to: string): void {
  load();
  const list = stacks.get(from);
  if (!list || from === to) return;
  const next = new Map(stacks);
  next.delete(from);
  next.set(to, [...list, ...(next.get(to) ?? NONE)].slice(0, STASH_LIMIT));
  save(next);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// `chat`'s stack, newest first.
export function useStash(chat: string): readonly StashedDraft[] {
  return useSyncExternalStore(
    subscribe,
    () => {
      load();
      return stacks.get(chat) ?? NONE;
    },
    () => NONE,
  );
}

/// Tests: forget the page's stacks so the next read loads them again.
export function resetStashForTests(): void {
  stacks = new Map();
  loaded = false;
}

/// A stashed draft on one line, for its row in the list.
export function stashPreview(entry: StashedDraft): string {
  return withoutInlineTokens(entry.text).replace(/\s+/g, " ").trim().slice(0, 120);
}
