import type { AcpmuxSnapshot } from "./model";
import { type StringKey, type Translate } from "./i18n";
import { isAgentHome, projectLabel, sessionTitle } from "./sessionList";

/// Empty-state copy: keys of the pane's string table.
export const EMPTY_STATE_LABELS = {
  prompt: "empty.prompt",
  /// `{project}` is replaced by the session's folder name, drawn underlined.
  promptIn: "empty.promptIn",
} as const satisfies Record<string, StringKey>;

/// The hero's folder: the sidebar's project label, or nothing for no folder or the home folder.
export function projectName(cwd: string | undefined): string | undefined {
  if (!cwd?.replace(/\/+$/, "") || isAgentHome(cwd)) return undefined;
  const label = projectLabel(cwd);
  return label === "~" ? undefined : label;
}

/// The shown chat's name where the pane names it (a subagent's "Subagent of" pill): its summary's
/// title, "New chat" only for a chat with no session yet. An existing chat whose summary has not
/// arrived goes by its listed title, else the neutral "Chat": it is not new.
export function shownChatName(snapshot: Pick<AcpmuxSnapshot, "summary" | "sessionId" | "sessions">, t: Translate) {
  if (snapshot.summary) return sessionTitle(snapshot.summary, t);
  if (!snapshot.sessionId) return t("sidebar.newChat");
  const listed = snapshot.sessions.find((session) => session.sessionId === snapshot.sessionId);
  return listed?.title?.trim() || t("cmuxLink.kind.chat");
}

/// A new chat has no turns, rows or queued work. The host can identify an unsent
/// chat before a summary exists; attached chats use their own session's summary.
/// A daemon that doesn't count turns still exposes older history for an old session.
export function isNewChat(snapshot: AcpmuxSnapshot, newSession = false): boolean {
  const summary = snapshot.summary;
  // The host knows a direct chat is new before an agent can produce a summary.
  // Keep its conversion and project controls usable while that agent starts.
  if (newSession && !summary && !snapshot.sessionId && !snapshot.canLoadOlder)
    return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0;
  // A harness switch's new chat has no session yet; its summary is the one the switch draws.
  if (!summary || (summary.sessionId !== snapshot.sessionId && !snapshot.switching)) return false;
  // While connecting or reconnecting, a chat its summary says has no turns is still new: it keeps
  // its hero (the page's cached chat, the chat before the drop) instead of a blank transcript.
  if (snapshot.connection.startsWith("failed")) return false;
  // A summary without a turn count (the sidebar's listing, an older acpmux) says nothing about the
  // chat's turns: until its attach answers (`chatRead`), an existing chat is still loading, not new,
  // so it draws the loading state instead of the hero. Attached with no rows and no older history,
  // it has no turns.
  const turns = summary.turnCount ?? (snapshot.canLoadOlder ? 1 : snapshot.chatRead === true ? 0 : undefined);
  if (turns === undefined) return false;
  return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0 && turns === 0;
}
