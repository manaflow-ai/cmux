// The composer picks a new chat starts from (cmux#57157): where it runs (lastNewChatPlace.ts), the agent
// and model a Cloud start names (cloudAgentPick.ts) and the permission mode it starts in
// (cloudModePick.ts). Each is the person's last pick, and every new agent chat starts from it: a new
// workspace, a new tab, a split right or down, the palette's New Chat, `cmux new-tab`. Each of those
// opens its own page (or adopts a warm one), so a pick held in one page's memory never reached the
// next: Cloud stayed picked, but its Bypass permissions went back to Auto.
//
// So every such pick lives here, in this origin's localStorage, which every agent page shares
// (AgentPaneView.sharedDataStore, newtab/settledCache.ts): a pick on one page is what the next page
// reads, and a page already open (a warm New Tab page) hears it through the `storage` event. The
// harness and model of a chat on this Mac are lastPick.ts's, which the app also keeps across
// launches; acpmux decides a chat on this Mac's start mode (startMode.ts).
import { useSyncExternalStore } from "react";

export type PickStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem?(name: string): void;
};

function pageStore(): PickStore | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/// The key `refused` holds a pick under when the page has no store at all.
const NO_STORE: PickStore = { getItem: () => null, setItem: () => undefined };

export type NewChatPick<T> = {
  readonly key: string;
  /// The kept pick, or undefined (none yet, no storage, or a value this build can't read).
  get(store?: PickStore): T | undefined;
  /// Keeps `value` for every page; undefined forgets it.
  set(value: T | undefined, store?: PickStore): void;
  subscribe(listener: () => void): () => void;
  /// `get()`, drawn again when this page or another one picks.
  use(): T | undefined;
};

/// One kept pick under `key`. `parse` takes what storage holds and returns the pick, or undefined for
/// a value this build can't read (written by hand or by another build): as if nothing was picked.
export function newChatPick<T>(key: string, parse: (value: unknown) => T | undefined): NewChatPick<T> {
  const listeners = new Set<() => void>();
  // The last raw value read and what it parsed to, so `use` returns the same object until it changes.
  let cached: { raw: string | null; value: T | undefined } | undefined;
  // A pick a store refused (full, blocked; `NO_STORE`: none at all), by store: it still holds on
  // this page, only not on the next.
  const refused = new WeakMap<PickStore, { value: T | undefined }>();
  const notify = () => {
    for (const listener of listeners) listener();
  };
  const read = (store: PickStore | undefined): T | undefined => {
    const held = refused.get(store ?? NO_STORE);
    if (held) return held.value;
    let raw: string | null;
    try {
      raw = store?.getItem(key) ?? null;
    } catch {
      return undefined;
    }
    if (cached && cached.raw === raw) return cached.value;
    let value: T | undefined;
    try {
      value = raw === null ? undefined : parse(JSON.parse(raw));
    } catch {
      value = undefined;
    }
    cached = { raw, value };
    return value;
  };
  const onStorage = (event: Event) => {
    const changed = (event as StorageEvent).key;
    // `null`: the whole store was cleared.
    if (changed === key || changed === null) notify();
  };
  const subscribe = (listener: () => void) => {
    if (listeners.size === 0) globalThis.window?.addEventListener?.("storage", onStorage);
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) globalThis.window?.removeEventListener?.("storage", onStorage);
    };
  };
  const get = (store: PickStore | undefined = pageStore()) => read(store);
  return {
    key,
    get,
    set(value, store = pageStore()) {
      let kept = false;
      try {
        if (value === undefined && store?.removeItem) store.removeItem(key);
        else store?.setItem(key, JSON.stringify(value ?? null));
        kept = store !== undefined;
      } catch {
        // A full or refused store: below.
      }
      if (kept && store) refused.delete(store);
      else refused.set(store ?? NO_STORE, { value });
      notify();
    },
    subscribe,
    use() {
      return useSyncExternalStore(
        subscribe,
        () => get(),
        () => get(),
      );
    },
  };
}
