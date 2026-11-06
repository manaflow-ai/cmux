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
const snapshotSave: {
  next?: AcpmuxSnapshot;
  timer?: ReturnType<typeof setTimeout>;
  hooked?: boolean;
} = {};
function writeSnapshot(): void {
  clearTimeout(snapshotSave.timer);
  snapshotSave.timer = undefined;
  const next = snapshotSave.next;
  snapshotSave.next = undefined;
  if (!next) return;
  try {
    sessionStorage.setItem("cmux.acpmux.snapshot", JSON.stringify({ ...next, sessions: savedSessions(next) }));
  } catch {
    // Painting remains live when storage is unavailable or full.
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
  if (!snapshotSave.hooked && typeof window !== "undefined") {
    snapshotSave.hooked = true;
    window.addEventListener("pagehide", writeSnapshot);
    document.addEventListener("visibilitychange", () => document.visibilityState === "hidden" && writeSnapshot());
  }
  snapshotSave.timer ??= setTimeout(writeSnapshot, SNAPSHOT_SAVE_MS);
}

export function cachedSnapshot(): AcpmuxSnapshot {
  try {
    const value = JSON.parse(sessionStorage.getItem("cmux.acpmux.snapshot") ?? "null");
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
