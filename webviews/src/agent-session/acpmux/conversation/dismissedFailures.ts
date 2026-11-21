// The failed turns whose error card the person closed with its × (cmux#48434: "there should also be a
// place where i can dismiss this"). Kept by the turn summary's row id in the page's storage, so a closed
// card stays closed when the chat is opened again; the newest DISMISSED_LIMIT ids are kept.
import { useSyncExternalStore } from "react";

const KEY = "cmux.agent.dismissedFailures";
export const DISMISSED_LIMIT = 500;

function load(): string[] {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : [];
  } catch {
    return [];
  }
}

let ids = new Set(load());
const listeners = new Set<() => void>();

export function isFailureDismissed(rowId: string): boolean {
  return ids.has(rowId);
}

export function dismissFailure(rowId: string): void {
  if (ids.has(rowId)) return;
  const next = [...ids, rowId].slice(-DISMISSED_LIMIT);
  ids = new Set(next);
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(next));
  } catch {
    // A blocked store keeps the card closed for this page only.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (the same chat in another tab) closed a card.
  const changed = (event: StorageEvent) => {
    if (event.key !== KEY && event.key !== null) return;
    ids = new Set(load());
    listener();
  };
  globalThis.addEventListener?.("storage", changed);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", changed);
  };
}

/// Whether the person closed this failed turn's card.
export function useFailureDismissed(rowId: string): boolean {
  return useSyncExternalStore(
    subscribe,
    () => ids.has(rowId),
    () => ids.has(rowId),
  );
}
