// The pane's reload copy of its snapshot (sessionStorage) and the turn-end test App.tsx runs between
// renders. Kept out of App.tsx so the copy's timer and cache outlive a Fast Refresh of App, and App
// exports only components (a component module with other exports can't take a hot update).
import type { AcpmuxSnapshot } from "./model";
import type { AcpmuxSessionEntry } from "./sessionList";
import { acpmuxPerf, markStorageRefused } from "./perf";

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
/// one a display frame, and serializing the whole transcript took main-thread time that grew with
/// the chat; a 250 ms timer still wrote every held row and up to 200 chats four times a second for
/// no reader. It is written only as the page hides or unloads, when a reload can next need it. Only
/// the bridge's `receive` (App.tsx: the gallery, the preview) saves one; the app's own pages read
/// acpmux through the direct client and never did.
const SNAPSHOT_KEY = "cmux.acpmux.snapshot";
const snapshotSave: {
  next?: AcpmuxSnapshot;
  hooked?: Window;
} = {};
function writeSnapshot(): void {
  const next = snapshotSave.next;
  snapshotSave.next = undefined;
  if (!next) return;
  let text = "";
  try {
    text = JSON.stringify({ ...next, sessions: savedSessions(next) });
    sessionStorage.setItem(SNAPSHOT_KEY, text);
  } catch {
    // Painting remains live when storage is unavailable or full; the trace says the copy was lost.
    markStorageRefused(SNAPSHOT_KEY, text.length);
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
export function saveSnapshot(next: AcpmuxSnapshot): void {
  snapshotSave.next = next;
  // With no timer, the hide is the only write: hooked on the page's own window, which a test that
  // brings its own document replaces under this module.
  if (typeof window !== "undefined" && snapshotSave.hooked !== window) {
    snapshotSave.hooked = window;
    window.addEventListener("pagehide", writeSnapshot);
    document.addEventListener("visibilitychange", writeIfHidden);
  }
}
function writeIfHidden(): void {
  if (document.visibilityState === "hidden") writeSnapshot();
}

export function cachedSnapshot(): AcpmuxSnapshot {
  try {
    const value = JSON.parse(sessionStorage.getItem(SNAPSHOT_KEY) ?? "null");
    if (value?.type === "snapshot" && Array.isArray(value.rows) && Array.isArray(value.sessions)) {
      acpmuxPerf.markAgent("snapshotPaint");
      // `connection`, `drewKeptTail`, `chatRead` and `turnsEnded` are facts about a live client, and this one is
      // restored: no client has drawn anything yet, so this document's first paint is its own to report.
      return {
        ...emptySnapshot(),
        ...value,
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
