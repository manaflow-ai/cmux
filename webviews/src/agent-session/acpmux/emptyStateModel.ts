import type { AcpmuxSnapshot } from "./model";
import { isAgentHome, projectLabel } from "./sessionList";

/// A new chat's folder name: the sidebar's project label, or nothing for no folder or the home folder.
export function projectName(cwd: string | undefined): string | undefined {
  if (!cwd?.replace(/\/+$/, "") || isAgentHome(cwd)) return undefined;
  const label = projectLabel(cwd);
  return label === "~" ? undefined : label;
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
  // the plain new chat (EmptyState.tsx) instead of a blank transcript, and never a different screen.
  if (snapshot.emitReason.startsWith("failed")) return false;
  const turns = summary.turnCount ?? (snapshot.canLoadOlder ? 1 : 0);
  return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0 && turns === 0;
}
