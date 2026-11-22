// The failed turns whose error card the person closed with its × (cmux#48434: "there should also be a
// place where i can dismiss this"). Kept by chat and turn summary row id (`<chat>:<row>`; a row id is
// only unique within its chat) in the page's storage, so a closed card stays closed when the chat is
// opened again; the newest DISMISSED_LIMIT ids are kept.
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

const keyOf = (chat: string, rowId: string) => `${chat}:${rowId}`;

export function isFailureDismissed(chat: string, rowId: string): boolean {
  return ids.has(keyOf(chat, rowId));
}

export function dismissFailure(chat: string, rowId: string): void {
  const key = keyOf(chat, rowId);
  if (ids.has(key)) return;
  const next = [...ids, key].slice(-DISMISSED_LIMIT);
  ids = new Set(next);
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(next));
  } catch {
    // A blocked store keeps the card closed for this page only.
  }
  for (const listener of listeners) listener();
}

// Another page (the same chat in another tab) closed a card: one listener for the page, which reads
// the key once and tells every footer.
const changed = (event: StorageEvent) => {
  if (event.key !== KEY && event.key !== null) return;
  ids = new Set(load());
  for (const listener of listeners) listener();
};

function subscribe(listener: () => void) {
  if (listeners.size === 0) globalThis.addEventListener?.("storage", changed);
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.removeEventListener?.("storage", changed);
  };
}

/// Whether the person closed this failed turn's card in `chat`.
export function useFailureDismissed(chat: string, rowId: string): boolean {
  const key = keyOf(chat, rowId);
  return useSyncExternalStore(
    subscribe,
    () => ids.has(key),
    () => ids.has(key),
  );
}
