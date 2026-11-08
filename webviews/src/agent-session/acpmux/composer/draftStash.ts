// Stash: the composer's draft put aside with one key (⌃S), the prompt emptied for something else,
// and the draft brought back (⌃S on an empty prompt, or a pick from the Stashed chip's list). Each
// chat holds a short stack, newest first. The stacks live in localStorage, shared by every pane of
// the app, so a reload or a released page keeps them: each change starts from what is stored now,
// never from this page's older copy, and other panes' changes arrive by the `storage` event. An
// entry too large for localStorage keeps its chips' contents in IndexedDB (`chipStore`) under its
// id, and in localStorage only the chips without their contents (`held` names them); nothing
// stashed is ever kept in this page alone.
import { useSyncExternalStore } from "react";
import { withoutInlineTokens, type ComposerAttachment } from "../attachments";

export type StashedDraft = {
  id: string;
  text: string;
  attachments: ComposerAttachment[];
  at: number;
  /// The chips whose contents are in the chip store, not in `attachments` (`stashedChips`).
  held?: string[];
};

/// The most drafts one chat holds; a stash past it lets the oldest go.
export const STASH_LIMIT = 5;
/// The most chats whose stacks are kept; the stack used longest ago goes first.
export const STASH_CHATS = 50;
/// An entry keeps its chips' contents in localStorage only below this many characters of JSON.
const STORED_ENTRY_MAX = 256 * 1024;
export const STORAGE_KEY = "cmux.agentPane.draftStash.v1";

/// Where a large entry's chips are kept, by entry id.
export type ChipStore = {
  put(id: string, chips: readonly ComposerAttachment[]): Promise<void>;
  get(id: string): Promise<ComposerAttachment[] | undefined>;
  drop(id: string): Promise<void>;
  ids(): Promise<string[]>;
};

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
      .map(({ held, ...entry }) => ({
        ...entry,
        attachments: Array.isArray(entry.attachments) ? entry.attachments : [],
        ...(Array.isArray(held) && held.length ? { held: held.filter((id) => typeof id === "string") } : {}),
      }))
      .slice(0, STASH_LIMIT);
    if (drafts.length) out.set(chat, drafts);
  }
  return out;
}

/// `entry` as localStorage keeps it: a large one with its chips' contents left out, named in
/// `held` (the chip store has them).
export function storedEntry(entry: StashedDraft): StashedDraft {
  if (entry.held || !entry.attachments.length || JSON.stringify(entry).length <= STORED_ENTRY_MAX) return entry;
  const held = entry.attachments.filter((chip) => chip.data !== undefined || chip.text !== undefined);
  return {
    ...entry,
    attachments: entry.attachments.map(({ data: _data, text: _text, ...chip }) => chip),
    held: held.map((chip) => chip.id),
  };
}

const read = (): Map<string, StashedDraft[]> => {
  const store = storage();
  return store ? parseStacks(store.getItem(STORAGE_KEY)) : new Map(stacks as Map<string, StashedDraft[]>);
};

const idsOf = (all: Stacks) => new Set([...all.values()].flatMap((list) => list.map((entry) => entry.id)));

function load(): void {
  if (loaded) return;
  loaded = true;
  stacks = read();
  // Another pane's stash, take or move: this page shows it at once.
  globalThis.addEventListener?.("storage", (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    stacks = read();
    emit();
  });
  // Chips whose entry is gone (a pane that closed between its write and its drop).
  void chipStore
    .ids()
    .then((ids) => {
      const live = idsOf(read());
      for (const id of ids) if (!live.has(id)) void chipStore.drop(id).catch(() => undefined);
    })
    .catch(() => undefined);
}

/// Stores `next` (made from `before`, what was stored), letting go of the chips of every held
/// entry it no longer has, but `taking`'s, which `stashedChips` reads and then drops.
function save(before: Stacks, next: Map<string, StashedDraft[]>, taking?: string): void {
  // The stacks used longest ago go once there are too many chats.
  while (next.size > STASH_CHATS) next.delete(next.keys().next().value!);
  stacks = next;
  try {
    storage()?.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(next)));
  } catch {
    // Full or unavailable: this page's copy still holds them.
  }
  const kept = idsOf(next);
  for (const list of before.values())
    for (const entry of list)
      if (entry.held && entry.id !== taking && !kept.has(entry.id))
        void chipStore.drop(entry.id).catch(() => undefined);
  emit();
}

let serial = 0;

/// Puts `draft` on top of `chat`'s stack. Nothing is stashed for an empty draft, nor when a large
/// draft's chips cannot be kept (no IndexedDB): the prompt keeps the draft then. Resolves to
/// whether it was stashed; a draft that needs no chip store is stashed before this returns.
export function stashDraft(
  chat: string,
  text: string,
  attachments: readonly ComposerAttachment[],
): Promise<boolean> | boolean {
  if (!text.trim() && attachments.length === 0) return false;
  load();
  const full: StashedDraft = {
    id: `stash-${Date.now().toString(36)}-${(serial++).toString(36)}`,
    text,
    attachments: [...attachments],
    at: Date.now(),
  };
  const entry = storedEntry(full);
  const push = () => {
    const before = read();
    const next = new Map(before);
    const list = [entry, ...(next.get(chat) ?? NONE)].slice(0, STASH_LIMIT);
    // Most recently used last, so the oldest key is the one to let go.
    next.delete(chat);
    next.set(chat, list);
    save(before, next);
    return true;
  };
  if (!entry.held) return push();
  return chipStore.put(entry.id, full.attachments).then(push, () => false);
}

/// Takes the draft `id` (else the newest) off `chat`'s stack, or undefined when there is none.
/// Its chips come from `stashedChips`.
export function takeStashed(chat: string, id?: string): StashedDraft | undefined {
  load();
  const before = read();
  const list = before.get(chat) ?? NONE;
  const entry = id === undefined ? list[0] : list.find((candidate) => candidate.id === id);
  if (!entry) return undefined;
  const next = new Map(before);
  const rest = list.filter((candidate) => candidate.id !== entry.id);
  if (rest.length) next.set(chat, [...rest]);
  else next.delete(chat);
  save(before, next, entry.id);
  return entry;
}

/// A taken entry's chips with their contents: its own, or the chip store's for a held one (then
/// dropped there). A held chip the store lost is left out; the rest come back.
export function stashedChips(entry: StashedDraft): Promise<ComposerAttachment[]> | ComposerAttachment[] {
  if (!entry.held) return entry.attachments;
  const held = new Set(entry.held);
  return chipStore.get(entry.id).then(
    (chips) => {
      void chipStore.drop(entry.id).catch(() => undefined);
      return chips ?? entry.attachments.filter((chip) => !held.has(chip.id));
    },
    () => entry.attachments.filter((chip) => !held.has(chip.id)),
  );
}

/// Drops the draft `id` from `chat`'s stack.
export function dropStashed(chat: string, id: string): void {
  const entry = takeStashed(chat, id);
  if (entry?.held) void chipStore.drop(entry.id).catch(() => undefined);
}

/// A new chat's stack follows it once it has a session.
export function moveStash(from: string, to: string): void {
  load();
  const before = read();
  const list = before.get(from);
  if (!list || from === to) return;
  const next = new Map(before);
  next.delete(from);
  next.set(to, [...list, ...(next.get(to) ?? NONE)].slice(0, STASH_LIMIT));
  save(before, next);
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

/// The chip store: IndexedDB, one record per held entry. A page without it stashes no large draft.
const DB_NAME = "cmux.agentPane.draftStash";
const DB_STORE = "chips";
let opened: Promise<IDBDatabase> | undefined;
const database = (): Promise<IDBDatabase> =>
  (opened ??= new Promise<IDBDatabase>((resolve, reject) => {
    const request = globalThis.indexedDB?.open(DB_NAME, 1);
    if (!request) return reject(new Error("no IndexedDB"));
    request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch((error: unknown) => {
    opened = undefined;
    throw error;
  }));
const run = <T>(mode: IDBTransactionMode, op: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> =>
  database().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const tx = db.transaction(DB_STORE, mode);
        const request = op(tx.objectStore(DB_STORE));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      }),
  );
const indexedChips: ChipStore = {
  put: (id, chips) => run("readwrite", (store) => store.put(chips, id)).then(() => undefined),
  get: (id) =>
    run("readonly", (store) => store.get(id)).then((chips: unknown) =>
      Array.isArray(chips) ? (chips as ComposerAttachment[]) : undefined,
    ),
  drop: (id) => run("readwrite", (store) => store.delete(id)).then(() => undefined),
  ids: () => run("readonly", (store) => store.getAllKeys()).then((keys) => keys.map(String)),
};
let chipStore: ChipStore = indexedChips;

/// Tests: forget the page's stacks so the next read loads them again, and use `chips` (else
/// IndexedDB) as the chip store.
export function resetStashForTests(chips?: ChipStore): void {
  stacks = new Map();
  loaded = false;
  chipStore = chips ?? indexedChips;
}

/// A stashed draft on one line, for its row in the list.
export function stashPreview(entry: StashedDraft): string {
  return withoutInlineTokens(entry.text).replace(/\s+/g, " ").trim().slice(0, 120);
}
