import type { StartedSession } from "../started/startedSessions";
import type { SubsessionRow } from "../subagents/subsessions";

/// A chat also present among sub-sessions gets its one row there. Keep the input order and
/// the actual StartedSession objects for the rest. This is O(started + subsessions), including
/// when both lists grow to thousands of agents (the former nested .some was O(their product)).
export function startedChatsOutsideSubsessions(
  started: readonly StartedSession[],
  subsessions: readonly Pick<SubsessionRow, "sessionId">[],
): StartedSession[] {
  const subIds = new Set(subsessions.map((subsession) => subsession.sessionId));
  return started.filter((child) => !subIds.has(child.sessionId));
}
