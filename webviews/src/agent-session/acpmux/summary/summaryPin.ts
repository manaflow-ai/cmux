// The pinned summary's state, one per user (PINNED-SUMMARY P1): pinned or not, and which
// sections the user hid. A wide pane (at least 960 px, the pane's own window) shows the pinned
// card at the top right; a narrow one falls back to the header popover. The button, the card
// and the menu read the same stores, so a change in one shows in all at once.
import { useMemo, useSyncExternalStore } from "react";

export const PIN_KEY = "cmux.agent-pane.summary.pinned";
export const HIDDEN_KEY = "cmux.agent-pane.summary.hidden";
export const WIDE_QUERY = "(min-width: 960px)";

const listeners = new Set<() => void>();

function read(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value);
  } catch {
    // Storage is optional (private contexts); the choice lasts until reload.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  // Another pane of the app changed it.
  const storage = (event: StorageEvent) => {
    if (event.key === PIN_KEY || event.key === HIDDEN_KEY) listener();
  };
  const host = typeof window === "undefined" ? undefined : window;
  host?.addEventListener("storage", storage);
  return () => {
    listeners.delete(listener);
    host?.removeEventListener("storage", storage);
  };
}

const wideQuery = () => (typeof window === "undefined" ? undefined : window.matchMedia?.(WIDE_QUERY));

function subscribeWide(listener: () => void): () => void {
  const media = wideQuery();
  media?.addEventListener("change", listener);
  return () => media?.removeEventListener("change", listener);
}

export function useWidePane(): boolean {
  return useSyncExternalStore(
    subscribeWide,
    () => wideQuery()?.matches ?? false,
    () => false,
  );
}

/// Pinned by default, as the Codex app's card is; shown only in a wide pane.
export function useSummaryPinned(): { pinned: boolean; wide: boolean; shown: boolean; setPinned(next: boolean): void } {
  const pinned = useSyncExternalStore(
    subscribe,
    () => read(PIN_KEY) !== "0",
    () => true,
  );
  const wide = useWidePane();
  return { pinned, wide, shown: pinned && wide, setPinned: (next) => write(PIN_KEY, next ? "1" : "0") };
}

/// The section ids the user hid from the summary's menu.
export function useHiddenSections(): [ReadonlySet<string>, (id: string, hidden: boolean) => void] {
  const raw = useSyncExternalStore(
    subscribe,
    () => read(HIDDEN_KEY) ?? "[]",
    () => "[]",
  );
  const hidden = useMemo(() => {
    try {
      const list = JSON.parse(raw) as unknown;
      return new Set(Array.isArray(list) ? list.filter((id): id is string => typeof id === "string") : []);
    } catch {
      return new Set<string>();
    }
  }, [raw]);
  const set = (id: string, hide: boolean) => {
    const next = new Set(hidden);
    if (hide) next.add(id);
    else next.delete(id);
    write(HIDDEN_KEY, JSON.stringify([...next]));
  };
  return [hidden, set];
}
