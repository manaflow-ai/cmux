import { type StringKey, type Translate } from "../i18n";
import { retryLabel, sessionRetry, sessionRetryKey, type RetryQuiet } from "../subagents/retryState";
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

/// A sub-session whose last turn was stopped reads stopped, not done (it offers Resume).
const STOPPED = { word: "subagents.state.cancelled", status: "stopped" } as const;
const stateOf = (child: StartedSession) =>
  child.state === "idle" && child.stoppedAt !== undefined ? STOPPED : SESSION_STATE[child.state];

/// The retry acpmux waits to run for a started chat's failed turn (retryState.ts ``sessionRetry``).
const retryOf = (child: StartedSession) => {
  const phase = sessionRetry(child);
  return phase.kind === "retrying" ? phase.retry : undefined;
};

/// A started chat's status as a subagent's reads, for the counts and the Active and Done lists: one
/// acpmux retries is running again.
export const sessionStatus = (child: StartedSession): SubagentStatus =>
  retryOf(child) ? "running" : stateOf(child).status;

/// A started chat's state in words ("Done", "Retrying (2/4) after a capacity error" once the retry has
/// waited the shared bound), as its row says it, and whether it works (the turning ring): while it runs
/// (no word), or while acpmux retries it. `connectionQuiet`: the drawing component's
/// `useConnectionQuietKeys`.
export function sessionStateText(
  t: Translate,
  child: StartedSession,
  connectionQuiet: RetryQuiet,
): { text: string; working: boolean; word: string } {
  const word = t(stateOf(child).word);
  const retry = retryOf(child);
  const lasting = connectionQuiet(sessionRetryKey(child.sessionId), retry !== undefined);
  // A retry inside the bound reads as running: the turning ring, no word.
  if (retry) return { text: lasting ? retryLabel(t, retry) : "", working: true, word };
  // Running is the turning ring, never a word (Leo, 2026-11-23: "\"running\" doesn't need text. it can
  // usually just be. you can put symbols for state.").
  if (stateOf(child).status === "running") return { text: "", working: true, word };
  return { text: word, working: false, word };
}

/// The started chats in list order: waiting on the person first, then running, failed and idle,
/// each newest first.
export function orderedSessions(sessions: readonly StartedSession[]): StartedSession[] {
  const rank = { waiting: 0, running: 1, failed: 2, idle: 3 } as const;
  return [...sessions].sort(
    (a, b) => rank[a.state] - rank[b.state] || (b.createdAt ?? -Infinity) - (a.createdAt ?? -Infinity),
  );
}
