// The project a New Tab page starts on, decided on its first frame (Leo 2026-10-19: "new tab still
// paints first frame as unexplored ... it's indecisive between 'defaults' and 'recently used'").
// A page that just mounted has no chat list until its own daemon connection answers, so it drew
// "Choose folder" and then flipped to the project used last. Every agent page shares one website
// data store (AgentPaneView.sharedDataStore), so this origin's localStorage is the app run's: each
// page that hears this Mac's chat list keeps its newest chat folders here, and the next New Tab page
// reads them before it paints. A blocked store, or a run that has heard no list yet, leaves the
// page to wait for its own list (NewTabScreen holds the chip's place, never a wrong label).
import type { AcpmuxSnapshot } from "../model";
import { firstProject, recentLocalFolders } from "../sessionList";

const KEY = "cmux.acpmux.newTab.recentFolders.v1";
/// Enough newest folders that the home folder or a removed project never leaves none.
const KEPT = 12;

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

let lastWritten: string | undefined;
/// The last list read: a streaming turn emits a snapshot per row with the same `sessions` array.
let lastSessions: AcpmuxSnapshot["sessions"] | undefined;

/// Keeps the newest chat folders of `snapshot`, a list this Mac's daemon sent (`origin` local).
/// An empty list keeps the last one: a connection lists nothing before its first answer.
export function rememberRecentFolders(snapshot: Pick<AcpmuxSnapshot, "origin" | "sessions">): void {
  if (snapshot.origin !== "local" || snapshot.sessions === lastSessions) return;
  lastSessions = snapshot.sessions;
  const folders = recentLocalFolders(snapshot.sessions, KEPT);
  if (folders.length === 0) return;
  const text = JSON.stringify(folders);
  if (text === lastWritten) return;
  lastWritten = text;
  try {
    storage()?.setItem(KEY, text);
  } catch {
    // A full or blocked store: the next page waits for its own list.
  }
}

/// The folders a page of this run kept last, newest first.
export function rememberedRecentFolders(): string[] {
  try {
    const value = JSON.parse(storage()?.getItem(KEY) ?? "null") as unknown;
    return Array.isArray(value) ? value.filter((cwd): cwd is string => typeof cwd === "string" && cwd !== "") : [];
  } catch {
    return [];
  }
}

/// The project a New Tab with no folder of its own starts on, read once as it mounts: the newest
/// in the chats it already has (another page's list, or a spare page's own), else the newest a page
/// of this run kept. Undefined when neither knows one yet. The kept folders are this Mac's: a page
/// on another machine (no `home`, NewTabPageMachine) never starts on one of them.
export function initialRecentProject(
  sessions: AcpmuxSnapshot["sessions"],
  home: string | undefined,
  known: readonly string[] | null | undefined,
): string | undefined {
  return (
    firstProject(recentLocalFolders(sessions), home, known) ??
    (home ? firstProject(rememberedRecentFolders(), home, known) : undefined)
  );
}

/// A new page's start (tests).
export function resetRecentProjectForTests(): void {
  lastWritten = undefined;
  lastSessions = undefined;
}
