import { startedPullRequests, startedState, type StartedSession } from "../started/startedSessions";
import type { AlsoHere } from "./alsoHere";

/// One listed chat as a row: its title, with the machine for a peer's.
export function alsoHereRow({ entry }: AlsoHere): StartedSession {
  const title = entry.displayTitle || entry.title || entry.name || entry.sessionId;
  const pullRequests = startedPullRequests(entry);
  return {
    sessionId: entry.sessionId,
    title: entry.peer ? `${entry.peer}/${title}` : title,
    state: startedState(entry),
    ...(pullRequests ? { pullRequests } : {}),
    ...(entry.createdAt !== undefined ? { createdAt: entry.createdAt } : {}),
    ...(entry.harness ? { harness: entry.harness } : {}),
  };
}
