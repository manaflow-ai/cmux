import { type StringKey, type Translate } from "../i18n";
import { retryLabel, sessionRetry } from "../subagents/retryState";
import type { StartedSession, StartedState } from "../started/startedSessions";
import type { SubagentStatus } from "../summary/subagentStatusListModel";

/// Each state's word, and the status it counts as beside the subagents: an idle chat's turn ended,
/// so it reads done.
const SESSION_STATE: Record<StartedState, { word: StringKey; status: SubagentStatus }> = {
  running: { word: "subagents.state.running", status: "running" },
  waiting: { word: "subagents.state.waiting", status: "waiting" },
  failed: { word: "subagents.state.failed", status: "failed" },
  idle: { word: "subagents.state.completed", status: "done" },
};

/// The retry acpmux waits to run for a started chat's failed turn (retryState.ts ``sessionRetry``).
const retryOf = (child: StartedSession) => {
  const phase = sessionRetry(child);
  return phase.kind === "retrying" ? phase.retry : undefined;
};

/// A started chat's status as a subagent's reads, for the counts and the Active and Done lists: one
/// acpmux retries is running again.
export const sessionStatus = (child: StartedSession): SubagentStatus =>
  retryOf(child) ? "running" : SESSION_STATE[child.state].status;

/// A started chat's state in words ("Running", "Done", "Retrying (2/4) after a capacity error"), as
/// its row says it, and whether it works (the turning ring) while acpmux retries it.
export function sessionStateText(t: Translate, child: StartedSession): { text: string; working: boolean } {
  const retry = retryOf(child);
  return retry
    ? { text: retryLabel(t, retry), working: true }
    : { text: t(SESSION_STATE[child.state].word), working: false };
}

/// The started chats in list order: waiting on the person first, then running, failed and idle,
/// each newest first.
export function orderedSessions(sessions: readonly StartedSession[]): StartedSession[] {
  const rank = { waiting: 0, running: 1, failed: 2, idle: 3 } as const;
  return [...sessions].sort(
    (a, b) => rank[a.state] - rank[b.state] || (b.createdAt ?? -Infinity) - (a.createdAt ?? -Infinity),
  );
}
