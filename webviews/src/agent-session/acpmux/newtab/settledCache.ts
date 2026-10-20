// What a New Tab page already knew, for the next page that mounts (Leo 2026-10-18: closing or
// opening a workspace re-mounted its page, which read every settled value again and jittered). Every
// agent page shares one website data store (AgentPaneView.sharedDataStore), so this origin's
// localStorage is the app run's: a page that mounts draws the last All chats first page on its
// first frame (the machine chip's name comes with the page's context, #22211). The chat index's
// pushes (`deviceChats`) stay the only reason to read the first page again; a blocked store only
// leaves the page to read as before.
import type { AllChatsDesign, AllChatsRow } from "./AllChatsList";
import { devicePushCount } from "./deviceChats";

const CHATS_KEY = "cmux.acpmux.newTab.chats";

/// The All chats list's first page (no query) as a page last read it.
export type SettledChats = { rows: AllChatsRow[]; nextCursor?: string; ready: boolean; design?: AllChatsDesign };

/// The `deviceChats` push count the stored first page answers, in this page; pushes past it are
/// changes no read here has taken in yet.
let reflected = 0;

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

function read<T>(key: string): T | undefined {
  try {
    const raw = storage()?.getItem(key);
    return raw ? (JSON.parse(raw) as T) : undefined;
  } catch {
    return undefined;
  }
}

function write(key: string, value: unknown): void {
  try {
    storage()?.setItem(key, JSON.stringify(value));
  } catch {
    // Storage unavailable: the next page reads its first page as before.
  }
}

export function settledChats(): SettledChats | undefined {
  const value = read<SettledChats>(CHATS_KEY);
  return value && Array.isArray(value.rows) && value.rows.length > 0 ? value : undefined;
}

/// Keeps a first page read when the push count was `atPush` (taken as the read went out, so a push
/// during the read still counts as unread).
export function rememberChats(value: SettledChats, atPush: number): void {
  reflected = Math.max(reflected, atPush);
  write(CHATS_KEY, value);
}

/// True when the chat index pushed a change since the stored first page was read in this page.
export function chatsChangedSinceSettled(): boolean {
  return devicePushCount() > reflected;
}
