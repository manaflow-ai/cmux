// The New Tab page's chats, one store for every page (Leo 2026-10-19 12:15): each window's New Tab
// listed the chats its own daemon connection last delivered, so a torn-off window (whose hidden
// pages hear the daemon late) showed another list than the main window's, and a page that just
// mounted drew no chats until its connection answered. Every agent page shares one website data
// store (AgentPaneView.sharedDataStore), so this origin's localStorage is the app run's: each
// connected page writes the newest list it received, every page reads the newest any page wrote,
// and another page's write reaches a page already showing as a `storage` event, so its rows update
// in place. A page draws the store's list on its first frame (no refetch, no empty list); a blocked
// store leaves each page its own list, as before. With `agent.pageHost` on each page has its own
// store, so this is each page's own list again.
import { useSyncExternalStore } from "react";
import type { AcpmuxSnapshot } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";

type Sessions = AcpmuxSnapshot["sessions"];

const KEY = "cmux.acpmux.newTab.sessions.v1";
/// The chats a New Tab lists come from the newest few; the rest only keep their transcripts from
/// coming back as device chats (recentChatCards) and their folders in the project picker, so each
/// keeps just the fields those need.
const FULL = 60;

type Stored = { at: number; sessions: AcpmuxSessionEntry[] };

let current: Stored | undefined;
let loaded = false;
/// The last list this page published (the direct client keeps an unchanged session's entry).
let lastPublished: Sessions | undefined;
let lastText: string | undefined;
const listeners = new Set<() => void>();

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

function parse(raw: string | null | undefined): Stored | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<Stored> | null;
    if (!value || typeof value.at !== "number" || !Array.isArray(value.sessions)) return undefined;
    const sessions = value.sessions.filter(
      (session): session is AcpmuxSessionEntry =>
        !!session && typeof session === "object" && typeof (session as AcpmuxSessionEntry).sessionId === "string",
    );
    return { at: value.at, sessions };
  } catch {
    return undefined;
  }
}

function notify(): void {
  for (const listener of listeners) listener();
}

function onStorage(event: StorageEvent): void {
  // `key: null` is a clear() of the whole store.
  if (event.key !== KEY && event.key !== null) return;
  const next = event.key === null ? undefined : parse(event.newValue);
  if (next && current && next.at < current.at) return;
  const text = next ? JSON.stringify(next.sessions) : undefined;
  current = next;
  // Another page wrote the list this page shows: nothing on screen changes.
  if (text === lastText) return;
  lastText = text;
  notify();
}

function load(): void {
  if (loaded) return;
  loaded = true;
  current = parse(storage()?.getItem(KEY));
  lastText = current ? JSON.stringify(current.sessions) : undefined;
  try {
    globalThis.window?.addEventListener("storage", onStorage);
  } catch {
    // No window: this page's own writes still reach it.
  }
}

/// Whether `session` waits on the user: it lists first whatever its age, so it stays whole.
const urgent = (session: AcpmuxSessionEntry) => (session.pendingPermissions ?? 0) > 0 || !!session.indicator;

/// What the store keeps of `sessions`: the daemon's chats, newest first (a tie on its id), the newest
/// `FULL` and those waiting on the user whole, the others as the ids that keep their transcripts out
/// of the device chats.
function kept(sessions: Sessions): AcpmuxSessionEntry[] {
  // Every page talks to this Mac's daemon, whose list names other machines' chats too (`peer`).
  const ordered = (sessions as AcpmuxSessionEntry[])
    .filter(Boolean)
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0) || a.sessionId.localeCompare(b.sessionId));
  return ordered.map((session, index) =>
    index < FULL || urgent(session)
      ? session
      : ({
          sessionId: session.sessionId,
          ...(session.agentSessionId ? { agentSessionId: session.agentSessionId } : {}),
          ...(session.updatedAt !== undefined ? { updatedAt: session.updatedAt } : {}),
          ...(session.cwd ? { cwd: session.cwd } : {}),
          ...(session.host ? { host: session.host } : {}),
          ...(session.hostKind ? { hostKind: session.hostKind } : {}),
          ...(session.peer ? { peer: session.peer } : {}),
          archived: true,
        } as AcpmuxSessionEntry),
  );
}

function encode(sessions: Sessions, at: number): string {
  return JSON.stringify({ at, sessions: kept(sessions) } satisfies Stored);
}

function sameEntries(a: Sessions, b: Sessions | undefined): boolean {
  if (a === b) return true;
  if (!b || a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1) if (a[index] !== b[index]) return false;
  return true;
}

/// Whether `snapshot` is a live list of this Mac's daemon: one the client has read (a connection's
/// first emits list nothing yet), on a connection acpmux calls local (a chat on another machine
/// lists only its own chat; an older acpmux names no origin), and not connecting, cut off, a
/// gallery or a debug page.
function publishable(snapshot: Pick<AcpmuxSnapshot, "connection" | "origin" | "listedSessions">): boolean {
  const connection = snapshot.connection;
  if (snapshot.listedSessions !== true || snapshot.origin !== "local") return false;
  if (connection === "disconnected" || connection === "debug" || connection === "gallery") return false;
  return !connection.startsWith("connecting") && !connection.startsWith("reconnecting");
}

/// Takes a page's daemon snapshot into the store, when it is publishable and its list changed.
/// `connection` is why the client emitted ("connected", "session changed", an event's kind).
export function publishSessions(
  snapshot: Pick<AcpmuxSnapshot, "connection" | "origin" | "listedSessions" | "sessions">,
  at = Date.now(),
): void {
  if (!publishable(snapshot)) return;
  load();
  // Every snapshot (one per transcript row while a turn streams) builds a new list of the same
  // entries (the direct client keeps an unchanged session's entry): compare entries, not the list.
  if (sameEntries(snapshot.sessions, lastPublished)) return;
  lastPublished = snapshot.sessions;
  const text = encode(snapshot.sessions, at);
  const stored = JSON.parse(text) as Stored;
  const listed = JSON.stringify(stored.sessions);
  // The list the store already holds (this page's or another's): no write, no event elsewhere.
  if (listed === lastText && current) return;
  try {
    storage()?.setItem(KEY, text);
  } catch {
    // A full or blocked store: this page still lists the newest it has.
  }
  current = stored;
  lastText = listed;
  notify();
}

/// The chats a New Tab page lists: the newest list any page received, else the page's own.
export function sharedSessions(own: Sessions): Sessions {
  load();
  return current && current.sessions.length > 0 ? current.sessions : own;
}

function subscribe(listener: () => void): () => void {
  load();
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function value(): Stored | undefined {
  load();
  return current;
}

const unsubscribed = () => () => {};

// A page on the in-page mock daemon (a tour or a demo inside the app): it lists its own mock chats,
// never the app's, though the mock names itself local.
let mockPage = false;

/// The page runs on the in-page mock daemon (App.tsx, `transport: "mock"`).
export function markMockPage(mock = true): void {
  mockPage = mock;
}

/// Whether a page lists the shared chats: a New Tab page (`page`, its context) of this Mac's daemon
/// (before its handshake no origin is named, and another machine's context turns the store off with
/// `privateChatLists`, as Debug Settings `newTab.privateChatLists` does), whose daemon is not down: a
/// down daemon shows that, not chats the page cannot open. An older acpmux names no origin
/// (`unknown`) and may be another machine's, as `publishable` reads it.
export function sharesChatList(
  page: { privateChatLists?: boolean } | undefined,
  snapshot: Pick<AcpmuxSnapshot, "origin" | "connection">,
): boolean {
  if (!page || page.privateChatLists || mockPage) return false;
  if (snapshot.origin !== undefined && snapshot.origin !== "local") return false;
  return snapshot.connection !== "disconnected" && snapshot.connection !== "debug";
}

/// `sharedSessions` as a hook: the page re-renders when it or another page publishes. `enabled`
/// false (not a New Tab page, a chat on another machine, or Debug Settings
/// `newTab.privateChatLists`) lists the page's own chats and does not listen.
export function useSharedSessions(own: Sessions, enabled = true): Sessions {
  const stored = useSyncExternalStore(enabled ? subscribe : unsubscribed, value, value);
  if (!enabled) return own;
  return stored && stored.sessions.length > 0 ? stored.sessions : own;
}

/// A new page's start (tests): forget this page's copy and read the store again.
export function reloadChatStoreForTests(): void {
  loaded = false;
  current = undefined;
  lastPublished = undefined;
  lastText = undefined;
  try {
    globalThis.window?.removeEventListener("storage", onStorage);
  } catch {
    // No window.
  }
  load();
}

export const CHAT_STORE_KEY_FOR_TESTS = KEY;

/// What a page writes to the store for `sessions` received at `at` (tests stand in for another page).
export function encodeChatStoreForTests(sessions: Sessions, at: number): string {
  return encode(sessions, at);
}
