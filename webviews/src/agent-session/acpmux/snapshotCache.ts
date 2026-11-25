// The pane's reload copy of its snapshot (sessionStorage) and the turn-end test App.tsx runs between
// renders. Kept out of App.tsx so the copy's timer and cache outlive a Fast Refresh of App, and App
// exports only components (a component module with other exports can't take a hot update).
import type { AcpmuxSnapshot } from "./model";
import type { AcpmuxSessionEntry } from "./sessionList";
import { acpmuxPerf } from "./perf";

export function emptySnapshot(): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connecting",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
  };
}

/// The latest snapshot, kept for a reload of the page (`cachedSnapshot`). A streaming reply sends
/// one a display frame, and serializing the whole transcript each frame took main-thread time that
/// grew with the chat: it is written at most every SNAPSHOT_SAVE_MS, and at once as the page hides
/// or unloads, so a reload still finds the latest one.
const SNAPSHOT_SAVE_MS = 250;
/// The copy is a first paint: the rows in view and a margin, until the client's own page replaces
/// them. Writing the whole transcript cost time and bytes that grew with the chat (20,000 rows were
/// 5 MB, past sessionStorage's quota, so the write failed and a stale copy stayed): it keeps the
/// newest SAVED_ROWS rows, within SAVED_BYTES, and a cut copy says older history is left.
export const SAVED_ROWS = 200;
export const SAVED_BYTES = 1024 * 1024;
/// One saved snapshot per view (paneView.ts): the chats sharing one pane document each keep their own, so a
/// reload paints each chat's own last rows. The page's own snapshot (no view) keeps the key it always had.
export function snapshotKey(view: string | null = null): string {
  return view === null ? "cmux.acpmux.snapshot" : `cmux.acpmux.snapshot.view.${view}`;
}
const snapshotSave: {
  next: Map<string | null, AcpmuxSnapshot>;
  timer?: ReturnType<typeof setTimeout>;
  hooked?: boolean;
  /// Every view whose copy this page saved or read (the page's own, `null`, always): `clearSnapshot` removes each.
  views: Set<string | null>;
} = { next: new Map(), views: new Set([null]) };
/// The pages `clearSnapshot` dropped: each keeps no copy until it loads again. Held per page (its `window`), not
/// in this module: a module outlives the page in a test run (one module cache for every file, each with its own
/// document), and one file's dropped page must not stop the next file's saves.
const droppedPages = new WeakSet<object>();
function thisPage(): object {
  return typeof window === "undefined" ? globalThis : window;
}
/// The copy of `snapshot` with its newest `count` rows. The prompt index (`earlierPrompts`) stays
/// out: typed arrays do not survive JSON, and a reload reads it again.
function savedCopy(snapshot: AcpmuxSnapshot, count: number): string {
  const cut = snapshot.rows.length > count;
  return JSON.stringify({
    ...snapshot,
    // slice(-0) is the whole array: the smallest copy keeps no rows.
    rows: count === 0 ? [] : cut ? snapshot.rows.slice(-count) : snapshot.rows,
    earlierPrompts: undefined,
    sessions: savedSessions(snapshot),
    ...(cut ? { canLoadOlder: true, historyFrom: undefined } : {}),
  });
}
/// Writes every pending snapshot now (the page hiding does this; tests call it instead of waiting the debounce).
export function writeSnapshot(): void {
  clearTimeout(snapshotSave.timer);
  snapshotSave.timer = undefined;
  const pending = [...snapshotSave.next];
  snapshotSave.next.clear();
  for (const [view, next] of pending) writeOne(snapshotKey(view), next);
}
function writeOne(key: string, next: AcpmuxSnapshot): void {
  // Fewer rows until the copy fits the byte bound, then the store's quota; one chat's pasted text
  // can make a few rows large. A copy that fits nowhere is removed: a stale one would paint a chat
  // that has moved on.
  for (let count = SAVED_ROWS; ; count = Math.floor(count / 4)) {
    try {
      const value = savedCopy(next, count);
      if (value.length > SAVED_BYTES) {
        if (count === 0) break;
        continue;
      }
      sessionStorage.setItem(key, value);
      return;
    } catch {
      // Storage full: try a smaller tail.
    }
    if (count === 0) break;
  }
  try {
    sessionStorage.removeItem(key);
  } catch {
    // Painting remains live when storage is unavailable.
  }
}

/// Drops the reload copies (the page's and each view's) and any write still pending, and keeps none
/// for the rest of this page, so the next load starts empty and draws from its live client
/// (PaneBoundary: a copy holding the rows that threw would fail the same way).
export function clearSnapshot(): void {
  droppedPages.add(thisPage());
  clearTimeout(snapshotSave.timer);
  snapshotSave.timer = undefined;
  snapshotSave.next.clear();
  for (const view of snapshotSave.views) {
    try {
      sessionStorage.removeItem(snapshotKey(view));
    } catch {
      // Storage that is unavailable holds no copy to repaint.
    }
  }
}

/// Whether the shown chat's turn ended between two renders (App.tsx `pane.tabState`): the same chat
/// went idle, or its client counted an end. Only the same chat counts; switching away from a working
/// chat is no turn end. A turn that started and ended between two renders (a hidden page's batch,
/// drawn as one render) shows in `turnsEnded` alone; a new client counts from 0, so any change to a
/// count above 0 is an end.
export type TurnState = { session?: string; working: boolean; turnsEnded?: number };
export function turnEndedBetween(last: TurnState, next: TurnState): boolean {
  if (last.session !== next.session) return false;
  if (last.working && !next.working) return true;
  return next.turnsEnded !== undefined && next.turnsEnded > 0 && next.turnsEnded !== last.turnsEnded;
}

/// The reload copy keeps the newest SAVED_SESSIONS chats of the list, and the shown chat with its
/// parent and its own sub-sessions and forks at any age. The whole list (3,055 chats on a busy
/// Mac) was serialized on every write and went past sessionStorage's 5 MB, so the copy was lost;
/// the live list replaces this one as soon as the watch reads it.
export const SAVED_SESSIONS = 200;
const savedList: { sessions?: readonly AcpmuxSessionEntry[]; shown?: string; saved: AcpmuxSessionEntry[] } = {
  saved: [],
};
export function savedSessions(snapshot: AcpmuxSnapshot): AcpmuxSessionEntry[] {
  const { sessions, sessionId: shown } = snapshot;
  if (sessions.length <= SAVED_SESSIONS) return sessions;
  // A streaming reply writes with the list unchanged: it is chosen again only when it changes. Each
  // snapshot maps the list into a new array of the same cached entries (direct.ts `sessionEntries`),
  // so the entries are compared, not the array.
  const last = savedList.sessions;
  if (
    savedList.shown === shown &&
    last?.length === sessions.length &&
    (last === sessions || sessions.every((entry, index) => entry === last[index]))
  )
    return savedList.saved;
  const at = (entry: AcpmuxSessionEntry) => entry.activityAt ?? entry.updatedAt ?? 0;
  const newest = new Set(
    sessions
      .map((entry, index) => ({ at: at(entry), index }))
      .sort((a, b) => b.at - a.at)
      .slice(0, SAVED_SESSIONS)
      .map(({ index }) => index),
  );
  const own = sessions.find((entry) => entry.sessionId === shown);
  const kin = new Set([own?.parentId, own?.spawnedBy, own?.startedBy]);
  const related = (entry: AcpmuxSessionEntry) =>
    shown !== undefined &&
    (entry.sessionId === shown ||
      kin.has(entry.sessionId) ||
      entry.parentId === shown ||
      entry.spawnedBy === shown ||
      entry.startedBy === shown);
  const saved = sessions.filter((entry, index) => newest.has(index) || related(entry));
  Object.assign(savedList, { sessions, shown, saved });
  return saved;
}
export function saveSnapshot(next: AcpmuxSnapshot, view: string | null = null): void {
  if (droppedPages.has(thisPage())) return;
  snapshotSave.views.add(view);
  snapshotSave.next.set(view, next);
  if (!snapshotSave.hooked && typeof window !== "undefined") {
    snapshotSave.hooked = true;
    window.addEventListener("pagehide", writeSnapshot);
    document.addEventListener("visibilitychange", () => document.visibilityState === "hidden" && writeSnapshot());
  }
  snapshotSave.timer ??= setTimeout(writeSnapshot, SNAPSHOT_SAVE_MS);
}

export function cachedSnapshot(view: string | null = null): AcpmuxSnapshot {
  try {
    snapshotSave.views.add(view);
    const value = JSON.parse(sessionStorage.getItem(snapshotKey(view)) ?? "null");
    if (value?.type === "snapshot" && Array.isArray(value.rows) && Array.isArray(value.sessions)) {
      acpmuxPerf.markAgent("snapshotPaint");
      // `connection`, `drewKeptTail`, `chatRead` and `turnsEnded` are facts about a live client, and this one is
      // restored: no client has drawn anything yet, so this document's first paint is its own to report. The prompt
      // index is never restored: a copy saved by an older build holds it as rows, not columns, and a client reads
      // it again.
      return {
        ...emptySnapshot(),
        ...value,
        earlierPrompts: undefined,
        connection: "connecting",
        drewKeptTail: undefined,
        chatRead: undefined,
        turnsEnded: undefined,
      };
    }
  } catch {
    // A corrupt or unavailable session store must never block the pane.
  }
  return emptySnapshot();
}
