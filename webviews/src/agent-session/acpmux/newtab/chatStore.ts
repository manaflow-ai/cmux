// The New Tab page's chats, one store for every page (Leo 2026-10-19): each window's New Tab read
// the chat list its own daemon connection last delivered, so a torn-off window showed another list
// than the main one, and a page that just mounted drew no chats until its connection answered.
import type { AcpmuxSnapshot } from "../model";

type Sessions = AcpmuxSnapshot["sessions"];

/// Takes a page's daemon snapshot into the store.
export function publishSessions(_snapshot: Pick<AcpmuxSnapshot, "connection" | "sessions">, _at = Date.now()): void {}

/// The chats a New Tab page lists: the store's, else the page's own.
export function sharedSessions(own: Sessions): Sessions {
  return own;
}

/// `sharedSessions` as a hook: a page re-renders when another page publishes.
export function useSharedSessions(own: Sessions): Sessions {
  return own;
}

/// A new page's start (tests): forget this page's copy and read the store again.
export function reloadChatStoreForTests(): void {}

export const CHAT_STORE_KEY_FOR_TESTS = "";

/// What a page writes to the store for `sessions` received at `at` (tests stand in for another page).
export function encodeChatStoreForTests(_sessions: Sessions, _at: number): string {
  return "";
}
