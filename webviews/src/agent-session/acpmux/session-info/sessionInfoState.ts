// Session Info's state (SessionInfo.tsx): whether it is open, how wide it is, and which of its
// sections are folded. Each chat pane has its own (Leo, 2026-10-25: "it opens and closes on the
// other side too when you do one... they should all be individual per pane"): a toggle, a drag or a
// fold in one pane never reaches another. Every chat pane is its own page, so the page's copy is the
// pane's; it is kept in localStorage under the chat's session (``bindSessionInfoPane``) so the pane
// shows it again after a relaunch, and no page listens for another's writes. The last choice made in
// any pane is the default for a pane with none of its own yet (a new chat), so Session Info still
// opens for a first chat and stays off for new chats once closed (Leo, 2026-10-20). With no storage
// (a private window, a test) the page's own copy holds them.
import { useSyncExternalStore } from "react";

export type SessionInfoSectionId =
  | "environment"
  | "context"
  | "connectors"
  | "changes"
  | "sources"
  | "servers"
  | "subagents"
  | "tasks"
  | "outputs";
export type SessionInfoSections = Readonly<Record<SessionInfoSectionId, boolean>>;

/// The width a drag can give it, in px, and the width it opens at the first time.
export const SESSION_INFO_WIDTH = { min: 260, max: 560, fallback: 320 } as const;

/// Connectors starts folded to its one-line value (as in Claude Code desktop); the rest start open,
/// Context too (Leo, 2026-11-01: "context tho is pretty good i think to keep expanded by default? it
/// seemed like it was collapsed initially").
export const DEFAULT_SECTIONS: SessionInfoSections = {
  environment: true,
  context: true,
  connectors: false,
  changes: true,
  sources: true,
  servers: true,
  subagents: true,
  tasks: true,
  outputs: true,
};

/// The last choice made in any pane: the defaults for a pane with no state of its own. These were
/// the one shared state before 2026-10-25, so an old install's choice is the default too.
const OPEN_KEY = "cmux.agentPane.inspector.open";
const WIDTH_KEY = "cmux.agentPane.inspector.width";
const SECTIONS_KEY = "cmux.agentPane.inspector.sections";
/// Each chat's own state, one key per chat (`{ open, width, sections, at }`): a pane writes only its
/// chat's key, so two panes saving at once never undo each other's change.
export const SESSION_INFO_PANE_PREFIX = "cmux.agentPane.inspector.pane.";
/// The chats that have a key, newest first: `[sessionId, savedAt]` pairs, at most ``PANES_KEPT``.
/// A save prunes from it, so a toggle reads one small key, never every key in the page's storage.
export const SESSION_INFO_INDEX_KEY = "cmux.agentPane.inspector.index";
/// The chats kept: the newest ``PANES_KEPT`` seen in the last ``PANE_DAYS`` days, the pane's own always.
export const PANES_KEPT = 200;
const PANE_DAYS = 30;

export type SessionInfoState = {
  readonly open: boolean;
  readonly width: number;
  readonly sections: SessionInfoSections;
  readonly sourcesAll: boolean;
};
type State = SessionInfoState;
type Stored = { open?: unknown; width?: unknown; sections?: unknown; sourcesAll?: unknown; at?: unknown };

const clampWidth = (width: number) =>
  Math.round(Math.min(SESSION_INFO_WIDTH.max, Math.max(SESSION_INFO_WIDTH.min, width)));
const widthOf = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? clampWidth(value) : SESSION_INFO_WIDTH.fallback;

/// The saved sections' version. Before 2 every chat saved Context folded because that was the
/// default (each chat saves its whole state when a pane first shows it), not because the viewer folded
/// it, so a saved Context from before 2 gives way to today's default.
const SECTIONS_VERSION = 2;

function sectionsOf(value: unknown): SessionInfoSections {
  if (!value || typeof value !== "object") return DEFAULT_SECTIONS;
  const stored = value as Partial<Record<SessionInfoSectionId | "v", unknown>>;
  const sections = { ...DEFAULT_SECTIONS };
  for (const id of Object.keys(DEFAULT_SECTIONS) as SessionInfoSectionId[])
    if (typeof stored[id] === "boolean" && (id !== "context" || stored.v === SECTIONS_VERSION))
      sections[id] = stored[id];
  return sections;
}

/// The sections as they are saved: with their version.
const savedSections = (sections: SessionInfoSections) => ({ ...sections, v: SECTIONS_VERSION });

function parse(raw: string | null): unknown {
  try {
    return raw ? JSON.parse(raw) : undefined;
  } catch {
    return undefined;
  }
}

/// A chat's saved state, if it has one.
function storedState(raw: string | null): State | undefined {
  const stored = parse(raw) as Stored | undefined;
  if (!stored || typeof stored !== "object" || typeof stored.open !== "boolean") return undefined;
  return {
    open: stored.open,
    width: widthOf(stored.width),
    sections: sectionsOf(stored.sections),
    sourcesAll: stored.sourcesAll === true,
  };
}

/// One pane's Session Info state: what it shows, and the chat it is saved under while that chat has a
/// session. `storage` is the page's localStorage (a test passes its own).
export function createSessionInfoStore(storage: () => Storage | undefined = () => globalThis.localStorage) {
  const read = (key: string): string | null => {
    try {
      return storage()?.getItem(key) ?? null;
    } catch {
      return null;
    }
  };
  const write = (key: string, value: string | null) => {
    try {
      if (value === null) storage()?.removeItem(key);
      else storage()?.setItem(key, value);
    } catch {
      // Storage off: the page's copy still holds it.
    }
  };
  const paneKeys = (): string[] => {
    try {
      const all = storage();
      if (!all) return [];
      const keys: string[] = [];
      for (let index = 0; index < all.length; index++) {
        const key = all.key(index);
        if (key?.startsWith(SESSION_INFO_PANE_PREFIX)) keys.push(key);
      }
      return keys;
    } catch {
      return [];
    }
  };
  /// Open unless the viewer closed it: a first chat shows it.
  const defaults = (): State => ({
    open: read(OPEN_KEY) !== "0",
    width: widthOf(Number(read(WIDTH_KEY))),
    sections: sectionsOf(parse(read(SECTIONS_KEY))),
    sourcesAll: false,
  });
  const indexOf = (): [string, number][] => {
    const value = parse(read(SESSION_INFO_INDEX_KEY));
    if (!Array.isArray(value)) return [];
    return value.filter(
      (entry): entry is [string, number] =>
        Array.isArray(entry) && typeof entry[0] === "string" && typeof entry[1] === "number",
    );
  };
  /// Once per page: a chat whose key is in no index (a save another pane's index write lost) joins
  /// the index, so pruning reaches it. The only full scan of the storage.
  let swept = false;
  const adoptStrays = (index: [string, number][]) => {
    if (swept) return index;
    swept = true;
    const known = new Set(index.map(([sessionId]) => sessionId));
    const strays: [string, number][] = [];
    for (const key of paneKeys()) {
      const sessionId = key.slice(SESSION_INFO_PANE_PREFIX.length);
      if (known.has(sessionId)) continue;
      const at = (parse(read(key)) as Stored | undefined)?.at;
      strays.push([sessionId, typeof at === "number" ? at : 0]);
    }
    return strays.length > 0 ? [...index, ...strays] : index;
  };
  /// Saves `sessionId`'s state, and drops chats past the newest ``PANES_KEPT`` or older than
  /// ``PANE_DAYS`` from the index and their keys; never the pane's own (a clock set back, or a tie,
  /// must not drop the chat the pane shows). Only the small index is read and written again: a save
  /// another pane's index write loses delays its pruning, and a chat another pane saved after this
  /// pane read the index is never dropped (each chat's key carries its own time); neither loses a
  /// chat's state.
  const save = (sessionId: string, next: State) => {
    const now = Date.now();
    write(
      SESSION_INFO_PANE_PREFIX + sessionId,
      JSON.stringify({ ...next, sections: savedSections(next.sections), at: now }),
    );
    const others = adoptStrays(indexOf())
      .filter(([id]) => id !== sessionId)
      .sort((a, b) => b[1] - a[1]);
    const kept: [string, number][] = [[sessionId, now]];
    for (const [id, at] of others) {
      if (kept.length < PANES_KEPT && now - at < PANE_DAYS * 86_400_000) {
        kept.push([id, at]);
        continue;
      }
      // The index this pane read may be stale: another pane may have saved this chat since. Its own
      // key carries its `at`, so it goes only while that is exactly the one the index named; a chat
      // saved since stays, listed with its new time, even an earlier one (a clock set back), and the
      // next save prunes it if it is still due.
      const key = SESSION_INFO_PANE_PREFIX + id;
      const raw = read(key);
      if (raw === null) continue;
      const savedAt = (parse(raw) as Stored | undefined)?.at;
      if (typeof savedAt === "number" && savedAt !== at) kept.push([id, savedAt]);
      else write(key, null);
    }
    write(SESSION_INFO_INDEX_KEY, JSON.stringify(kept));
  };

  let pane: string | undefined;
  let state: State | undefined;
  /// The last saved state `shownFor` read for a chat the pane does not show yet, so the snapshot
  /// stays the same object while nothing changed.
  let peeked: { key: string; raw: string | null; state: State | undefined } | undefined;
  const listeners = new Set<() => void>();
  const current = (): State => (state ??= defaults());
  const update = (next: State, persist: boolean) => {
    if (persist && pane) save(pane, next);
    const changed = next !== state;
    state = next;
    if (changed) for (const listener of listeners) listener();
  };
  return {
    current,
    /// What the pane shows for chat `sessionId`, read before the pane is bound to it, so a pane
    /// switched to another chat draws that chat's state from its first frame: the chat's saved
    /// state, else what the pane shows now (a new chat inherits it).
    shownFor(sessionId: string | undefined): State {
      if (!sessionId || sessionId === pane) return current();
      const key = SESSION_INFO_PANE_PREFIX + sessionId;
      const raw = read(key);
      if (peeked?.key !== key || peeked.raw !== raw) peeked = { key, raw, state: storedState(raw) };
      return peeked.state ?? current();
    },
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    /// The pane shows chat `sessionId` (a relaunch, a new chat's first session, another chat in the
    /// pane): it shows that chat's saved state, or keeps what it shows and saves it as the chat's.
    /// No session (a new chat not started yet, a harness switch): nothing is saved until one comes,
    /// and the pane keeps what it shows.
    bind(sessionId: string | undefined) {
      if (sessionId === pane) return;
      pane = sessionId || undefined;
      if (!pane) return;
      const saved = storedState(read(SESSION_INFO_PANE_PREFIX + pane));
      if (saved) update(saved, false);
      else save(pane, current());
    },
    setOpen(open: boolean) {
      write(OPEN_KEY, open ? "1" : "0");
      update({ ...current(), open }, true);
    },
    /// A drag's width; `persist` stores it (at the drag's end, not on every step).
    setWidth(width: number, persist = true) {
      const next = clampWidth(width);
      if (persist) write(WIDTH_KEY, String(next));
      if (next !== current().width) update({ ...current(), width: next }, persist);
      else if (persist && pane) save(pane, current());
    },
    setSection(id: SessionInfoSectionId, open: boolean) {
      const sections = { ...current().sections, [id]: open };
      write(SECTIONS_KEY, JSON.stringify(savedSections(sections)));
      update({ ...current(), sections }, true);
    },
    setSourcesAll(all: boolean) {
      update({ ...current(), sourcesAll: all }, true);
    },
    /// Forgets every choice, every chat's too (the gallery and tests; it scans the storage).
    reset() {
      for (const key of [OPEN_KEY, WIDTH_KEY, SECTIONS_KEY, SESSION_INFO_INDEX_KEY, ...paneKeys()]) write(key, null);
      swept = false;
      pane = undefined;
      state = undefined;
      peeked = undefined;
      update(defaults(), false);
    },
  };
}

/// This page's pane.
const page = createSessionInfoStore();

/// The live state the pane shows for chat `sessionId` (the chat it shows; omitted: whatever it is bound to).
export const useSessionInfoState = (sessionId?: string): State => {
  const snapshot = () => page.shownFor(sessionId);
  return useSyncExternalStore(page.subscribe, snapshot, snapshot);
};
export const sessionInfoState = page.current;
/// Whether it is open, alone: a pane that needs only that is not drawn again on every drag step.
export const useSessionInfoOpen = (sessionId?: string): boolean => {
  const open = () => page.shownFor(sessionId).open;
  return useSyncExternalStore(page.subscribe, open, open);
};
/// Keys this pane's state by the chat it shows (useSessionInfo, from the snapshot's session).
export const bindSessionInfoPane = page.bind;
export const setSessionInfoOpen = page.setOpen;
export const setSessionInfoWidth = page.setWidth;
export const setSessionInfoSection = page.setSection;
export const setSessionInfoSourcesAll = page.setSourcesAll;
/// Forgets every choice: the gallery and the tests start each case on a clean slate.
export const resetSessionInfoState = page.reset;
