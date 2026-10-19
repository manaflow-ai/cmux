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
/// coming back as device chats (recentChatCards), so each keeps just the fields that needs.
const FULL = 60;

type Stored = { at: number; sessions: AcpmuxSessionEntry[] };

let current: Stored | undefined;
let loaded = false;
/// The last list this page published (the direct client keeps an unchanged list's identity).
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
  current = next;
  lastText = next ? JSON.stringify(next.sessions) : undefined;
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
  const ordered = (sessions as AcpmuxSessionEntry[]).filter(Boolean).sort(
    (a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0) || a.sessionId.localeCompare(b.sessionId),
  );
  return ordered.map((session, index) =>
    index < FULL || urgent(session)
      ? session
      : ({
          sessionId: session.sessionId,
          ...(session.agentSessionId ? { agentSessionId: session.agentSessionId } : {}),
          ...(session.updatedAt !== undefined ? { updatedAt: session.updatedAt } : {}),
          archived: true,
        } as AcpmuxSessionEntry),
  );
}

function encode(sessions: Sessions, at: number): string {
  return JSON.stringify({ at, sessions: kept(sessions) } satisfies Stored);
}

/// Takes a page's daemon snapshot into the store: only a connected page's (a page still connecting,
/// a gallery or a debug page lists nothing real), and only when its list changed.
export function publishSessions(snapshot: Pick<AcpmuxSnapshot, "connection" | "sessions">, at = Date.now()): void {
  if (snapshot.connection !== "connected") return;
  load();
  if (snapshot.sessions === lastPublished) return;
  lastPublished = snapshot.sessions;
  const text = encode(snapshot.sessions, at);
  const stored = JSON.parse(text) as Stored;
  const listed = JSON.stringify(stored.sessions);
  try {
    storage()?.setItem(KEY, text);
  } catch {
    // A full or blocked store: this page still lists the newest it has.
  }
  // The same list again (another identity, or another page's) changes nothing on screen.
  if (listed === lastText && current) {
    current = { ...current, at };
    return;
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

/// `sharedSessions` as a hook: the page re-renders when it or another page publishes. `enabled`
/// false (Debug Settings `newTab.privateChatLists`) lists the page's own chats, as before.
export function useSharedSessions(own: Sessions, enabled = true): Sessions {
  const stored = useSyncExternalStore(subscribe, value, value);
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
