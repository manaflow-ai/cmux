// The chats whose rolling summary line the person dismissed on this device (ChatSummaryLine's ×,
// https://github.com/manaflow-ai/cmux/issues/51749). Keyed by chat, not by summary: the daemon
// rewrites the summary after every turn, so a dismissal keyed by its text would bring the line back
// after the next reply. Both copies of the line (beside the name, and in the tab row) read it, so a
// dismissal hides both at once.
import { useSyncExternalStore } from "react";

const DISMISSED = "cmux.agentPane.summaryDismissed";
const MAX_DISMISSED = 500;

/// The last list read, by the text it was read from; `raw` undefined: storage is missing or refused
/// and this list is all there is (it lasts until the page reloads).
let cache: { raw: string | undefined; chats: readonly string[] } | undefined;
const listeners = new Set<() => void>();

function stored(): string | undefined {
  try {
    return globalThis.localStorage?.getItem(DISMISSED) ?? (globalThis.localStorage ? "[]" : undefined);
  } catch {
    return undefined;
  }
}

function read(): readonly string[] {
  // A dismissal storage refused lives only here: the stored list no longer has it.
  if (cache && cache.raw === undefined) return cache.chats;
  const raw = stored();
  if (raw === undefined) return cache?.chats ?? [];
  if (cache?.raw === raw) return cache.chats;
  try {
    const value: unknown = JSON.parse(raw);
    const chats = Array.isArray(value) ? value.filter((chat): chat is string => typeof chat === "string") : [];
    cache = { raw, chats };
    return chats;
  } catch {
    cache = { raw, chats: [] };
    return [];
  }
}

export function summaryDismissed(chat: string): boolean {
  return read().includes(chat);
}

export function rememberSummaryDismissed(chat: string): void {
  const chats = [...read().filter((other) => other !== chat), chat].slice(-MAX_DISMISSED);
  const raw = JSON.stringify(chats);
  let saved = false;
  try {
    if (globalThis.localStorage) {
      globalThis.localStorage.setItem(DISMISSED, raw);
      saved = true;
    }
  } catch {
    // Storage refused: the line stays hidden in this view until it reloads.
  }
  cache = { raw: saved ? raw : undefined, chats };
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Whether `chat`'s summary line was dismissed here; updates when either copy's × is pressed.
export function useSummaryDismissed(chat: string | undefined): boolean {
  return useSyncExternalStore(
    subscribe,
    () => (chat ? summaryDismissed(chat) : false),
    () => (chat ? summaryDismissed(chat) : false),
  );
}
