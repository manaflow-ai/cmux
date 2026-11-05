// Session Info's "Also working here" (alsoHere.ts): the other live chats in this chat's worktree or
// folder, or on its feature branch, each a row that opens that chat (ChildSessionRows.tsx, the rows
// Subagents draws). A peer's chat names its machine. Absent when there is none.
import { ChildSessionRows } from "./ChildSessionRows";
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

export function AlsoHereSection({ rows, onOpen }: { rows: readonly AlsoHere[]; onOpen?: (sessionId: string) => void }) {
  return (
    <ul className="acpmux-summary-list" data-also-here="">
      <ChildSessionRows sessions={rows.map(alsoHereRow)} onOpen={onOpen} />
    </ul>
  );
}
