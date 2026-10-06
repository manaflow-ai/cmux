// Saved marks on turns, from the thread minimap's bookmark button. The pane keeps them in an
// in-memory store, mirrored to the pane web view's localStorage under STORAGE_KEY, so a mark
// survives a reload of the pane. Keys are a turn's `user-<seq>#<prompt hash>` (model.ts MinimapTurn.key).
// They do not reach acpmux or other panes yet.
import { useSyncExternalStore } from "react";

export const STORAGE_KEY = "cmux.agentPane.threadBookmarks.v1";
/// The most marks kept; the oldest go first.
const MAX_MARKS = 500;

type Storage = Pick<globalThis.Storage, "getItem" | "setItem">;

export type BookmarkStore = {
  has(key: string): boolean;
  toggle(key: string): void;
  subscribe(listener: () => void): () => void;
  /// The marks now: a new set after every toggle, so a render that read it re-runs (useSyncExternalStore).
  snapshot(): ReadonlySet<string>;
};

export function createBookmarkStore(storage: Storage | undefined): BookmarkStore {
  let marks = new Set<string>(read(storage));
  const listeners = new Set<() => void>();
  return {
    has: (key) => marks.has(key),
    toggle(key) {
      marks = new Set(marks);
      if (!marks.delete(key)) marks.add(key);
      while (marks.size > MAX_MARKS) marks.delete(marks.values().next().value as string);
      try {
        storage?.setItem(STORAGE_KEY, JSON.stringify([...marks]));
      } catch {
        // Storage full or blocked: the mark stays for this page.
      }
      for (const listener of listeners) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    snapshot: () => marks,
  };
}

function read(storage: Storage | undefined): string[] {
  try {
    const parsed: unknown = JSON.parse(storage?.getItem(STORAGE_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}

const safeStorage = (): Storage | undefined => {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
};

let paneStore: BookmarkStore | undefined;
/// The pane's one store.
export const paneBookmarks = (): BookmarkStore => (paneStore ??= createBookmarkStore(safeStorage()));

/// The pane's marks and their toggle; the caller re-renders on each toggle.
export function useBookmarks(): { marks: ReadonlySet<string>; toggle: (key: string) => void } {
  const store = paneBookmarks();
  const marks = useSyncExternalStore(store.subscribe, store.snapshot, store.snapshot);
  return { marks, toggle: store.toggle };
}
