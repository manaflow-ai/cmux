// The New Tab widget view's data (Debug Settings `newTab.widgets`, Leo 2026-10-18): where a chat
// starts (this Mac and its recent projects) and the chats that need the user, each one dismissable.
// Every row comes from what the page already has: the composer's projects and the acpmux sessions.
import type { AcpmuxSnapshot } from "../model";
import { recentSessions } from "../NewTabPage";
import type { Project } from "../ProjectChooser";
import { activityTime, isAgentHome, sessionMark } from "../sessionList";

/// How many projects the Projects card lists.
export const WIDGET_PROJECTS = 4;
/// How many chats the Needs you card lists.
export const WIDGET_ATTENTION = 4;

/// A chat that needs the user: it asks for input, its last turn failed, or it lost its agent.
export type AttentionChat = {
  sessionId: string;
  title: string;
  state: "input" | "failed" | "error";
  /// A line of its latest reply, for the hover card.
  detail?: string;
  /// The dismiss key: a dismissed chat comes back once it changes again.
  key: string;
};

/// The chats that need the user, the ones asking for input first, then newest first; without the
/// ones dismissed (`dismissed` holds their keys).
export function attentionChats(
  sessions: AcpmuxSnapshot["sessions"],
  dismissed: ReadonlySet<string>,
  count = WIDGET_ATTENTION,
): AttentionChat[] {
  const chats: AttentionChat[] = [];
  for (const session of recentSessions(sessions, Number.POSITIVE_INFINITY, false)) {
    const mark = session.indicator === "failed" ? "failed" : sessionMark(session, false);
    if (mark !== "input" && mark !== "failed" && mark !== "error") continue;
    // Keyed on activity: a new question or failure shows the chat again, a warm or stop does not.
    const key = `${session.sessionId}@${activityTime(session) ?? 0}`;
    if (dismissed.has(key)) continue;
    chats.push({
      sessionId: session.sessionId,
      title: session.displayTitle ?? session.sessionId,
      state: mark,
      ...(session.preview ? { detail: session.preview } : {}),
      key,
    });
    if (chats.length >= count) break;
  }
  return chats;
}

/// The projects a chat can start in, the one used last first: by each folder's newest local chat,
/// then the rest in the picker's order. Never a private agent-home folder.
export function recentProjects(
  projects: readonly Project[],
  sessions: AcpmuxSnapshot["sessions"],
  count = WIDGET_PROJECTS,
): Project[] {
  const used = new Map<string, number>();
  for (const session of sessions) {
    if (!session.cwd || session.peer || session.hostKind === "cloud") continue;
    used.set(session.cwd, Math.max(used.get(session.cwd) ?? 0, activityTime(session) ?? 0));
  }
  return projects
    .filter((project) => !project.peer && !isAgentHome(project.cwd))
    .map((project, index) => ({ project, index, at: used.get(project.cwd) ?? -1 }))
    .sort((a, b) => b.at - a.at || a.index - b.index)
    .slice(0, count)
    .map((entry) => entry.project);
}

/// Where dismissed chats are kept: the pages' shared storage, so a dismiss holds on every New Tab
/// until cmux quits (agent pages use a non-persistent data store).
export const DISMISSED_STORAGE_KEY = "cmux.newTab.widgets.dismissed";
/// The dismisses kept; the oldest go first.
const DISMISSED_LIMIT = 200;

export function loadDismissed(): Set<string> {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(DISMISSED_STORAGE_KEY) ?? "[]");
    return new Set(Array.isArray(parsed) ? parsed.filter((key): key is string => typeof key === "string") : []);
  } catch {
    // No storage (a sandboxed page) or a malformed value: nothing dismissed.
    return new Set();
  }
}

export function saveDismissed(keys: ReadonlySet<string>): void {
  try {
    globalThis.localStorage?.setItem(DISMISSED_STORAGE_KEY, JSON.stringify([...keys].slice(-DISMISSED_LIMIT)));
  } catch {
    // No storage: the dismiss holds on this page only.
  }
}
