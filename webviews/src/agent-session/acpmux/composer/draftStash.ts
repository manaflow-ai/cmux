// Stash: the composer's draft put aside with one key (⌃S), the prompt emptied for something else,
// and the draft brought back (⌃S on an empty prompt, or a pick from the Stashed chip's list). Each
// chat holds a short stack, newest first. The stacks live in localStorage, shared by every pane of
// the app, so a reload or a released page keeps them. Each entry is a key of its own
// (`STORAGE_PREFIX` + chat + id): a stash adds one key and a take removes one, so two panes never
// write over each other's entries, and other panes' changes arrive by the `storage` event. A stash
// whose key cannot be written is not made (the prompt keeps the draft). An entry too large for
// localStorage keeps its chips' contents in IndexedDB (`chipStore`) under its id, and in
// localStorage only the chips without their contents (`held` names them); nothing stashed is ever
// kept in this page alone.
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
export const STORAGE_PREFIX = "cmux.agentPane.draftStash.v2:";

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

/// The key of `chat`'s entry `id`. A chat id never holds the separator once encoded.
export const entryKey = (chat: string, id: string) => `${STORAGE_PREFIX}${encodeURIComponent(chat)}:${id}`;

/// One stored entry, or undefined when it is not one.
export function parseEntry(raw: string | null | undefined): StashedDraft | undefined {
  if (!raw) return undefined;
  let entry: unknown;
  try {
    entry = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!entry || typeof entry !== "object") return undefined;
  const { id, text, at, attachments, held } = entry as Record<string, unknown>;
  if (typeof id !== "string" || typeof text !== "string" || typeof at !== "number") return undefined;
  const heldIds = Array.isArray(held) ? held.filter((chip): chip is string => typeof chip === "string") : [];
  return {
    id,
    text,
    at,
    attachments: Array.isArray(attachments) ? (attachments as ComposerAttachment[]) : [],
    ...(heldIds.length ? { held: heldIds } : {}),
  };
}

const newestFirst = (a: StashedDraft, b: StashedDraft) => b.at - a.at || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0);

/// Every chat's stack as stored now, newest first, malformed entries left out.
export function storedStacks(store: Pick<Storage, "length" | "key" | "getItem">): Map<string, StashedDraft[]> {
  const out = new Map<string, StashedDraft[]>();
  for (let index = 0; index < store.length; index += 1) {
    const key = store.key(index);
    if (!key?.startsWith(STORAGE_PREFIX)) continue;
    const rest = key.slice(STORAGE_PREFIX.length);
    const split = rest.lastIndexOf(":");
    const entry = parseEntry(store.getItem(key));
    if (split <= 0 || !entry || entry.id !== rest.slice(split + 1)) continue;
    let chat: string;
    try {
      chat = decodeURIComponent(rest.slice(0, split));
    } catch {
      continue;
    }
    out.set(chat, [...(out.get(chat) ?? []), entry]);
  }
  for (const list of out.values()) list.sort(newestFirst);
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

const idsOf = (all: Stacks) => new Set([...all.values()].flatMap((list) => list.map((entry) => entry.id)));

const refresh = () => {
  const store = storage();
  stacks = store ? storedStacks(store) : new Map();
  emit();
};

function load(): void {
  if (loaded) return;
  loaded = true;
  const store = storage();
  stacks = store ? storedStacks(store) : new Map();
  // Another pane's stash, take or move: this page shows it at once.
  globalThis.addEventListener?.("storage", (event: StorageEvent) => {
    if (event.key === null || event.key.startsWith(STORAGE_PREFIX)) refresh();
  });
  // Chips whose entry is gone (a pane that closed between its take and its drop).
  void chipStore
    .ids()
    .then((ids) => {
      const live = idsOf(store ? storedStacks(store) : new Map());
      for (const id of ids) if (!live.has(id)) void chipStore.drop(id).catch(() => undefined);
    })
    .catch(() => undefined);
}

/// Removes `chat`'s entry, its chips too when `chips` (a take keeps them for `stashedChips`).
function remove(store: Storage, chat: string, entry: StashedDraft, chips: boolean): void {
  store.removeItem(entryKey(chat, entry.id));
  if (chips && entry.held) void chipStore.drop(entry.id).catch(() => undefined);
}

/// Lets the oldest go: drafts past `STASH_LIMIT` in `chat`, and the stacks used longest ago past
/// `STASH_CHATS`.
function trim(store: Storage, chat: string): void {
  const all = storedStacks(store);
  for (const entry of (all.get(chat) ?? []).slice(STASH_LIMIT)) remove(store, chat, entry, true);
  const byUse = [...all].sort(([, a], [, b]) => (b[0]?.at ?? 0) - (a[0]?.at ?? 0));
  for (const [old, list] of byUse.slice(STASH_CHATS)) for (const entry of list) remove(store, old, entry, true);
}

/// Writes `entry` under `chat`; whether it was kept.
function write(store: Storage, chat: string, entry: StashedDraft): boolean {
  try {
    store.setItem(entryKey(chat, entry.id), JSON.stringify(entry));
    return true;
  } catch {
    return false;
  }
}

let serial = 0;
const newId = () =>
  `stash-${Date.now().toString(36)}-${(serial++).toString(36).padStart(6, "0")}-${Math.random().toString(36).slice(2, 8)}`;

/// Puts `draft` on top of `chat`'s stack. Nothing is stashed for an empty draft, nor when it
/// cannot be kept (no localStorage, a full one, a large draft's chips with no IndexedDB): the
/// prompt keeps the draft then. Whether it was stashed; a draft that needs no chip store is
/// stashed before this returns.
export function stashDraft(
  chat: string,
  text: string,
  attachments: readonly ComposerAttachment[],
): Promise<boolean> | boolean {
  if (!text.trim() && attachments.length === 0) return false;
  load();
  const store = storage();
  if (!store) return false;
  const full: StashedDraft = { id: newId(), text, attachments: [...attachments], at: Date.now() };
  const entry = storedEntry(full);
  const push = () => {
    if (!write(store, chat, entry)) {
      if (entry.held) void chipStore.drop(entry.id).catch(() => undefined);
      return false;
    }
    trim(store, chat);
    refresh();
    return true;
  };
  if (!entry.held) return push();
  return chipStore.put(entry.id, full.attachments).then(push, () => false);
}

/// Takes the draft `id` (else the newest) off `chat`'s stack, or undefined when there is none.
/// Its chips come from `stashedChips`.
export function takeStashed(chat: string, id?: string): StashedDraft | undefined {
  load();
  const store = storage();
  if (!store) return undefined;
  const list = storedStacks(store).get(chat) ?? NONE;
  const entry = id === undefined ? list[0] : list.find((candidate) => candidate.id === id);
  if (!entry) return undefined;
  remove(store, chat, entry, false);
  refresh();
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

/// A new chat's stack follows it once it has a session: each entry is written under the session
/// before it leaves the new chat's, so a failed write leaves it where it was.
export function moveStash(from: string, to: string): void {
  load();
  const store = storage();
  if (!store || from === to) return;
  const list = storedStacks(store).get(from);
  if (!list) return;
  for (const entry of list) if (write(store, to, entry)) store.removeItem(entryKey(from, entry.id));
  trim(store, to);
  refresh();
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
