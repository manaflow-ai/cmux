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

/// How often a page writes the store while its list keeps changing. Each write serializes every
/// chat (about 3,000 on a busy Mac) and wakes every other agent page, hidden ones too, to parse it,
/// and a list changes on nearly every frame while agents stream (each one moves its `updatedAt`).
/// The first change writes at once; later ones within the window write once, when it ends.
const PUBLISH_MS = 500;

let current: Stored | undefined;
let loaded = false;
/// The newest list this page received and has not written yet, and the window's timer: it is
/// armed only while a write went out in the last `PUBLISH_MS`, and ends when a window passes
/// with nothing to write. A page that hides or goes away writes what it holds first.
let pending: { sessions: Sessions; at: number; windowed: boolean } | undefined;
let windowTimer: ReturnType<typeof setTimeout> | undefined;
/// The last list this page published (the direct client keeps an unchanged session's entry).
let lastPublished: Sessions | undefined;
let lastText: string | undefined;
/// Another page's write this page has not parsed yet, and its `at`. Only a shown New Tab page reads
/// the list (`useSharedSessions`): a chat page and a hidden page keep the text and parse it when a
/// reader asks or the page shows. All agent pages share one renderer thread, so each hidden page's
/// parse of thousands of chats on every other page's write was the shown page's stutter too (Leo,
/// 2026-11-22: "lags every few frames or something. like a regular stutter").
let unparsed: { at: number; raw: string } | undefined;
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

/// The `at` and the sessions' JSON of a value `encode` wrote, read without parsing the list: a
/// write's text is `{"at":N,"sessions":[...]}`, so the list's own text is what follows the prefix.
const WRITTEN = /^\{"at":(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?),"sessions":(?=\[)/;
function written(raw: string | null | undefined): { at: number; listed: string } | undefined {
  const match = raw ? WRITTEN.exec(raw) : null;
  if (!raw || !match || !raw.endsWith("]}")) return undefined;
  return { at: Number(match[1]), listed: raw.slice(match[0].length, -1) };
}

/// The `at` of the newest list this page holds, parsed or not.
function heldAt(): number | undefined {
  return unparsed?.at ?? current?.at;
}

/// Parses the write this page held back, if any (a reader asked, or the page shows).
function materialize(): void {
  const held = unparsed;
  if (!held) return;
  unparsed = undefined;
  const next = parse(held.raw);
  if (next) current = next;
}

/// Whether a write's list is worth parsing now: some reader on this page shows it.
function readNow(): boolean {
  if (listeners.size === 0) return false;
  try {
    return globalThis.document?.visibilityState !== "hidden";
  } catch {
    return true;
  }
}

function onStorage(event: StorageEvent): void {
  // `key: null` is a clear() of the whole store.
  if (event.key !== KEY && event.key !== null) return;
  // Every page publishes the list it receives, so most writes hold the list this page already
  // has: those are read from their text, without parsing thousands of chats.
  const raw = event.key === null ? undefined : written(event.newValue);
  const at = heldAt();
  if (raw && at !== undefined && raw.at < at) return;
  if (raw && raw.listed === lastText && (current || unparsed)) {
    if (unparsed) unparsed = { at: raw.at, raw: event.newValue! };
    else if (current) current = { at: raw.at, sessions: current.sessions };
    return;
  }
  // A changed list nobody on this page shows: keep its text, parse it when a reader asks.
  if (raw && !readNow()) {
    unparsed = { at: raw.at, raw: event.newValue! };
    lastText = raw.listed;
    return;
  }
  unparsed = undefined;
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
    globalThis.window?.addEventListener("pagehide", flushPending);
    globalThis.document?.addEventListener("visibilitychange", flushPending);
    globalThis.document?.addEventListener("visibilitychange", onShow);
  } catch {
    // No window: this page's own writes still reach it.
  }
}

/// A page that shows parses the list it held back while hidden, and its readers draw it.
function onShow(): void {
  if (!unparsed || !readNow()) return;
  materialize();
  notify();
}

/// Whether `session` waits on the user: it lists first whatever its age, so it stays whole.
const urgent = (session: AcpmuxSessionEntry) => (session.pendingPermissions ?? 0) > 0 || !!session.indicator;

/// The store's order: newest first, a tie on the chat's id.
const newestFirst = (a: AcpmuxSessionEntry, b: AcpmuxSessionEntry) =>
  (b.updatedAt ?? 0) - (a.updatedAt ?? 0) || a.sessionId.localeCompare(b.sessionId);

/// What the store keeps of one listed chat at its place in the newest-first order: the whole entry,
/// or (past the newest `FULL`, not waiting on the user) the ids that keep its transcript out of the
/// device chats and its folder in the project picker.
function keptEntry(session: AcpmuxSessionEntry, index: number): AcpmuxSessionEntry {
  if (index < FULL || urgent(session)) return session;
  return {
    sessionId: session.sessionId,
    ...(session.agentSessionId ? { agentSessionId: session.agentSessionId } : {}),
    ...(session.updatedAt !== undefined ? { updatedAt: session.updatedAt } : {}),
    ...(session.cwd ? { cwd: session.cwd } : {}),
    ...(session.host ? { host: session.host } : {}),
    ...(session.hostKind ? { hostKind: session.hostKind } : {}),
    ...(session.peer ? { peer: session.peer } : {}),
    archived: true,
  } as AcpmuxSessionEntry;
}

/// Each listed entry's kept value and its JSON, whole and short, by the entry object. The direct
/// client keeps an unchanged session's entry, so a write re-encodes only the chats that changed since
/// the last one, not every chat on the Mac (about 3,000 on Leo's): a whole re-encode and parse of the
/// list every 500 ms while agents stream was 20 to 47 ms on the page's main thread, a regular
/// stutter (Leo, 2026-11-22: "lags every few frames or something. like a regular stutter").
type Encoded = { full?: [AcpmuxSessionEntry, string]; short?: [AcpmuxSessionEntry, string] };
const encodedEntries = new WeakMap<AcpmuxSessionEntry, Encoded>();

function encodedEntry(session: AcpmuxSessionEntry, index: number): [AcpmuxSessionEntry, string] {
  const whole = index < FULL || urgent(session);
  let cached = encodedEntries.get(session);
  if (!cached) encodedEntries.set(session, (cached = {}));
  const slot = whole ? "full" : "short";
  let value = cached[slot];
  if (!value) {
    const entry = keptEntry(session, index);
    value = cached[slot] = [entry, JSON.stringify(entry)];
  }
  return value;
}

/// The daemon's chats, newest first (a tie on its id): every page talks to this Mac's daemon, whose
/// list names other machines' chats too (`peer`).
function ordered(sessions: Sessions): AcpmuxSessionEntry[] {
  return (sessions as AcpmuxSessionEntry[]).filter(Boolean).sort(newestFirst);
}

/// What the store keeps of `sessions` (``keptEntry`` at each place), and the list's JSON text.
function keptList(sessions: Sessions): { sessions: AcpmuxSessionEntry[]; listed: string } {
  const kept: AcpmuxSessionEntry[] = [];
  const parts: string[] = [];
  ordered(sessions).forEach((session, index) => {
    const [entry, text] = encodedEntry(session, index);
    kept.push(entry);
    parts.push(text);
  });
  return { sessions: kept, listed: `[${parts.join(",")}]` };
}

/// The text a write stores: `{"at":N,"sessions":[...]}`, what `JSON.stringify` of a ``Stored`` makes.
function storedText(listed: string, at: number): string {
  return `{"at":${JSON.stringify(at)},"sessions":${listed}}`;
}

function encode(sessions: Sessions, at: number): string {
  return storedText(keptList(sessions).listed, at);
}

const rowKey = (session: AcpmuxSessionEntry) => `${session.sessionId}\u0000${session.peer ?? ""}`;

/// A page whose client holds only the newest window of the daemon's list (`sessionsWindowed`: the
/// first `SESSION_PAGE` rows; the rest are read only once something asks for every chat) and a page
/// that holds the whole list both publish here. Replacing the store with each, the New Tab's folder
/// list flipped between a window's few folders and the whole list's many twice a second. A window
/// says nothing about the chats older than its oldest row: those the store holds stay, after the
/// window's rows; everything in the window's range is the window's, so a chat gone from it goes.
/// `held` is in the store's order (`newestFirst`), so the rows past the window are its tail: one
/// pass, no row scans.
function overWindow(listed: Sessions, held: readonly AcpmuxSessionEntry[] | undefined): Sessions {
  if (!held || held.length === 0 || listed.length === 0) return listed;
  let oldest: AcpmuxSessionEntry | undefined;
  const inWindow = new Set<string>();
  for (const session of listed) {
    if (!session) continue;
    inWindow.add(rowKey(session));
    // A row with no time (sorted last) places the window nowhere: it would cover every held row.
    if (session.updatedAt === undefined) continue;
    if (!oldest || newestFirst(session, oldest) > 0) oldest = session;
  }
  if (!oldest) return listed;
  let start = held.length;
  while (start > 0 && newestFirst(held[start - 1], oldest) > 0) start -= 1;
  if (start === held.length) return listed;
  const merged = listed.slice();
  for (let index = start; index < held.length; index += 1) {
    if (!inWindow.has(rowKey(held[index]))) merged.push(held[index]);
  }
  return merged;
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
  snapshot: Pick<AcpmuxSnapshot, "connection" | "origin" | "listedSessions" | "sessionsWindowed" | "sessions">,
  at = Date.now(),
): void {
  if (!publishable(snapshot)) return;
  load();
  // Every snapshot (one per transcript row while a turn streams) builds a new list of the same
  // entries (the direct client keeps an unchanged session's entry): compare entries, not the list.
  if (sameEntries(snapshot.sessions, lastPublished)) return;
  lastPublished = snapshot.sessions;
  pending = { sessions: snapshot.sessions, at, windowed: snapshot.sessionsWindowed === true };
  // A write went out less than `PUBLISH_MS` ago: this list goes when the window ends.
  if (windowTimer !== undefined) return;
  writePending();
}

function endWindow(): void {
  windowTimer = undefined;
  flushPending();
}

/// Writes the list held back from the last window, unless another page wrote a newer one meanwhile:
/// a held-back list carries the `at` it arrived with, and must not replace a newer page's list.
function flushPending(): void {
  const at = heldAt();
  if (pending && at !== undefined && pending.at < at) pending = undefined;
  writePending();
}

/// Writes the list this page holds, if any, and starts a new window.
function writePending(): void {
  const next = pending;
  if (!next) return;
  pending = undefined;
  if (windowTimer !== undefined) clearTimeout(windowTimer);
  windowTimer = setTimeout(endWindow, PUBLISH_MS);
  write(next.sessions, next.at, next.windowed);
}

/// A window is laid over the store's rows (`overWindow`), read when it is written: a write that
/// waited out its window merges with what the store holds then. Merged to the text the store holds
/// already, it writes nothing, as an unchanged whole list does.
function write(sessions: Sessions, at: number, windowed: boolean): void {
  // The kept entries are this page's own (unchanged ones reused), not a parse of the text it stores.
  const { sessions: kept, listed } = keptList(windowed ? overWindow(sessions, current?.sessions) : sessions);
  // The list the store already holds (this page's or another's): no write, no event elsewhere.
  if (listed === lastText && (current || unparsed)) return;
  try {
    storage()?.setItem(KEY, storedText(listed, at));
  } catch {
    // A full or blocked store: this page still lists the newest it has.
  }
  current = { at, sessions: kept };
  unparsed = undefined;
  lastText = listed;
  notify();
}

/// The chats a New Tab page lists: the newest list any page received, else the page's own.
export function sharedSessions(own: Sessions): Sessions {
  load();
  materialize();
  return current && current.sessions.length > 0 ? current.sessions : own;
}

function subscribe(listener: () => void): () => void {
  load();
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function value(): Stored | undefined {
  load();
  materialize();
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
/// `privateChatLists`), whose daemon is not down: a
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
/// false (not a New Tab page, or a chat on another machine) lists the page's own chats and does not listen.
export function useSharedSessions(own: Sessions, enabled = true): Sessions {
  const stored = useSyncExternalStore(enabled ? subscribe : unsubscribed, value, value);
  if (!enabled) return own;
  return stored && stored.sessions.length > 0 ? stored.sessions : own;
}

/// A new page's start (tests): forget this page's copy and read the store again.
export function reloadChatStoreForTests(): void {
  // The page that goes away writes what it holds (`pagehide`).
  flushPending();
  if (windowTimer !== undefined) clearTimeout(windowTimer);
  windowTimer = undefined;
  loaded = false;
  current = undefined;
  unparsed = undefined;
  lastPublished = undefined;
  lastText = undefined;
  try {
    globalThis.window?.removeEventListener("storage", onStorage);
    globalThis.window?.removeEventListener("pagehide", flushPending);
    globalThis.document?.removeEventListener("visibilitychange", flushPending);
    globalThis.document?.removeEventListener("visibilitychange", onShow);
  } catch {
    // No window.
  }
  load();
}

export const CHAT_STORE_KEY_FOR_TESTS = KEY;

/// What a page writes to the store for `sessions` received at `at` (tests stand in for another page).
/// `windowed`: the list is only the newest window (`sessionsWindowed`), laid over the rows this
/// page's store holds now, as the other page would lay it over the same store.
export function encodeChatStoreForTests(sessions: Sessions, at: number, windowed = false): string {
  load();
  return encode(windowed ? overWindow(sessions, current?.sessions) : sessions, at);
}

/// A New Tab reader's subscription, as `useSharedSessions` makes it (tests).
export const subscribeChatStoreForTests = subscribe;
