// Saved marks on prompts, from the thread minimap's bookmark button. acpmux keeps them with the
// session (`_acpmux/bookmark_get`, `_acpmux/bookmark_set`), so a mark survives a reload, a restart
// and a move, and every pane on the chat shows it. A mark is the seq of the prompt's `user_message`
// record, which is also its row id (`user-<seq>`, direct.ts). The pane keeps a copy per session:
// loaded once from acpmux, changed at once on a toggle (taken back when acpmux refuses it), and
// replaced by acpmux's answer and by the `bookmarks` record another pane's change logs.
import { useEffect, useSyncExternalStore } from "react";

/// The mux record acpmux logs when a session's marks change; the pane attaches with it.
export const BOOKMARKS_KIND = "bookmarks";
/// The key of the marks this pane kept in localStorage before acpmux kept them.
export const STORAGE_KEY = "cmux.agentPane.threadBookmarks.v1";

/// How the store reaches acpmux: the pane's client (App.tsx), absent in a page without one.
export type BookmarkTransport = {
  get(sessionId: string): Promise<unknown>;
  set(sessionId: string, seq: number, bookmarked: boolean): Promise<unknown>;
};

const NONE: ReadonlySet<number> = new Set();
let transport: BookmarkTransport | undefined;
/// Bumped with each transport, so a minimap mounted before the pane connected reads its marks then.
let version = 0;
let marks = new Map<string, ReadonlySet<number>>();
/// Sessions read (or being read) from acpmux under the current transport.
let loaded = new Set<string>();
/// Toggles acpmux has not answered yet, by session: an older answer or record leaves them shown.
const pending = new Map<string, Map<number, boolean>>();
const listeners = new Set<() => void>();

const emit = () => {
  for (const listener of listeners) listener();
};

/// The seqs in a reply or record, or undefined when it holds no list.
function seqs(value: unknown): number[] | undefined {
  const list =
    value && typeof value === "object" && "bookmarks" in value ? (value as { bookmarks: unknown }).bookmarks : value;
  if (!Array.isArray(list)) return undefined;
  return list.filter((seq): seq is number => Number.isSafeInteger(seq) && seq > 0);
}

/// The marks acpmux holds for `sessionId`, with this pane's unanswered toggles over them.
function settle(sessionId: string, list: number[]): void {
  const next = new Set(list);
  for (const [seq, on] of pending.get(sessionId) ?? []) {
    if (on) next.add(seq);
    else next.delete(seq);
  }
  marks = new Map(marks).set(sessionId, next);
  emit();
}

/// The pane's acpmux connection, or none; a new one reads every session's marks again.
export function setBookmarkTransport(next: BookmarkTransport | undefined): void {
  transport = next;
  version += 1;
  // The marks shown stay until each session's read on the new connection answers (no dots leaving
  // and coming back on a reconnect); only the reads are asked again.
  loaded = new Set();
  pending.clear();
  emit();
}

/// A `bookmarks` record from acpmux: another pane (or this one) changed the session's marks.
export function bookmarksHeard(sessionId: string | undefined, list: unknown): void {
  const heard = seqs(list);
  if (sessionId && heard) settle(sessionId, heard);
}

/// Reads the session's marks from acpmux, once per transport, and brings over the marks this pane
/// kept in localStorage for it before (keys `<session>#user-<seq>#<hash>`). A key is forgotten
/// only once acpmux holds its mark; one it refused waits for the next attach.
function load(sessionId: string): void {
  const via = transport;
  if (!via || loaded.has(sessionId)) return;
  loaded.add(sessionId);
  via.get(sessionId).then(
    async (reply) => {
      if (via !== transport) return;
      const held = seqs(reply) ?? [];
      settle(sessionId, held);
      for (const { key, seq } of localMarks(sessionId))
        if (seq === undefined || held.includes(seq)) forgetLocalMark(key);
        else toggleWith(via, sessionId, seq, true, () => forgetLocalMark(key));
    },
    () => {
      // Unreachable or an older acpmux: no marks (the ones kept from the connection before go too),
      // and the next transport asks again.
      if (via !== transport) return;
      loaded.delete(sessionId);
      if (marks.has(sessionId)) {
        marks = new Map(marks);
        marks.delete(sessionId);
        emit();
      }
    },
  );
}

/// `kept` runs once acpmux has taken the change.
function toggleWith(via: BookmarkTransport, sessionId: string, seq: number, on: boolean, kept?: () => void): void {
  const waiting = pending.get(sessionId) ?? new Map<number, boolean>();
  pending.set(sessionId, waiting.set(seq, on));
  const before = marks.get(sessionId) ?? NONE;
  const shown = new Set(before);
  if (on) shown.add(seq);
  else shown.delete(seq);
  marks = new Map(marks).set(sessionId, shown);
  emit();
  const done = () => {
    if (pending.get(sessionId)?.get(seq) === on) pending.get(sessionId)?.delete(seq);
  };
  via.set(sessionId, seq, on).then(
    (reply) => {
      kept?.();
      if (via !== transport) return;
      done();
      const held = seqs(reply);
      if (held) settle(sessionId, held);
    },
    () => {
      if (via !== transport) return;
      // Refused (or unreachable): the mark goes back to what it was, unless a later toggle moved it.
      const later = pending.get(sessionId)?.get(seq) !== on;
      done();
      if (later) return;
      const back = new Set(marks.get(sessionId) ?? NONE);
      if (before.has(seq)) back.add(seq);
      else back.delete(seq);
      marks = new Map(marks).set(sessionId, back);
      emit();
    },
  );
}

/// The seq of a prompt row (`user-<seq>`), or undefined for a row acpmux has not logged yet.
export function promptSeq(rowId: string): number | undefined {
  const match = /^user-(\d+)$/.exec(rowId);
  const seq = match ? Number(match[1]) : NaN;
  return Number.isSafeInteger(seq) && seq > 0 ? seq : undefined;
}

/// The seq a row's pin is kept under: a prompt's (`user-<seq>`) or an answer's, its turn's
/// `turn_result` record (`summary-<seq>`); undefined for a row acpmux has not logged.
export function markSeq(rowId: string): number | undefined {
  const match = /^(?:user|summary)-(\d+)$/.exec(rowId);
  const seq = match ? Number(match[1]) : NaN;
  return Number.isSafeInteger(seq) && seq > 0 ? seq : undefined;
}

/// The session's marks and their toggle; the caller re-renders when they change.
export function useBookmarks(
  given: string | undefined,
  readOnly = false,
): {
  marks: ReadonlySet<number>;
  toggle: (seq: number) => void;
} {
  // Read only (a guest), no session: nothing is loaded from acpmux, migrated or set.
  const sessionId = readOnly ? undefined : given;
  const connected = useSyncExternalStore(subscribe, currentVersion, currentVersion);
  useEffect(() => {
    if (sessionId) load(sessionId);
  }, [sessionId, connected]);
  const snapshot = () => (sessionId ? (marks.get(sessionId) ?? NONE) : NONE);
  const shown = useSyncExternalStore(subscribe, snapshot, snapshot);
  return {
    marks: shown,
    toggle: (seq) => {
      if (sessionId && transport) toggleWith(transport, sessionId, seq, !shown.has(seq));
    },
  };
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const currentVersion = () => version;

/// The marks this pane kept for `sessionId` in localStorage: each key and its seq (none if unreadable).
function localMarks(sessionId: string): { key: string; seq: number | undefined }[] {
  const prefix = `${sessionId}#user-`;
  return readLocalMarks()
    .filter((key) => key.startsWith(prefix))
    .map((key) => ({ key, seq: promptSeq(key.slice(sessionId.length + 1).split("#")[0] ?? "") }));
}

function forgetLocalMark(key: string): void {
  try {
    const rest = readLocalMarks().filter((kept) => kept !== key);
    if (rest.length) globalThis.localStorage.setItem(STORAGE_KEY, JSON.stringify(rest));
    else globalThis.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage blocked: the key stays, and acpmux already holds its mark.
  }
}

function readLocalMarks(): string[] {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}
