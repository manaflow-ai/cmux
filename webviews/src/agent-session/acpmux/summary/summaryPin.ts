// The chat summary panel's state, one per user (PINNED-SUMMARY P1', Lawrence 2026-10-09: "i click, and it
// should always stay open until i close it"): open or closed, and which sections the user hid. Open is a
// choice that lasts (stored, restored on reload) until the user closes it; nothing else closes it. A wide
// pane (at least 960 px, the pane's own window) docks the panel as a right column; a narrow one docks it
// as a strip above the transcript. The button, the panel and the menu read the same stores.
import { useMemo, useSyncExternalStore } from "react";

export const OPEN_KEY = "cmux.agent-pane.summary.open";
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
    if (event.key === OPEN_KEY || event.key === HIDDEN_KEY) listener();
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

/// Closed until the user opens it; then open until the user closes it (the header button, the panel's
/// close button, or Escape inside the panel).
/// Opens or closes the summary panel (one stable function, so callers can register it once).
export function setSummaryOpen(next: boolean): void {
  write(OPEN_KEY, next ? "1" : "0");
}

export function useSummaryOpen(): { open: boolean; wide: boolean; setOpen(next: boolean): void } {
  const open = useSyncExternalStore(
    subscribe,
    () => read(OPEN_KEY) === "1",
    () => false,
  );
  const wide = useWidePane();
  return { open, wide, setOpen: setSummaryOpen };
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
