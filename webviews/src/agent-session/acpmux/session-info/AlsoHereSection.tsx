// Session Info's "Also working here" (alsoHere.ts): the other live chats in this chat's worktree or
// folder, or on its feature branch, each a row that opens that chat (ChildSessionRows.tsx, the rows
// Subagents draws). A peer's chat names its machine. Absent when there is none.
import { useEffect, useMemo, useState } from "react";
import { subscribePageDeadline } from "../../../ui/pageClock";
import type { AcpmuxSessionEntry } from "../sessionList";
import { ChildSessionRows } from "./ChildSessionRows";
import { startedPullRequests, startedState, type StartedSession } from "../started/startedSessions";
import { alsoHere, alsoHereExpiry, type AlsoHere } from "./alsoHere";

/// The chats working where `chatId` works, as of now: it redraws once, when the next listed chat
/// goes a day idle (`alsoHereExpiry`), not on every minute's tick.
export function useAlsoHere(chatId: string | undefined, all: readonly AcpmuxSessionEntry[] | undefined): AlsoHere[] {
  const [now, setNow] = useState(Date.now);
  const rows = useMemo(() => alsoHere(chatId, all, now), [chatId, all, now]);
  const expiry = alsoHereExpiry(rows, now);
  useEffect(() => {
    if (rows.length === 0) return;
    return subscribePageDeadline(
      () => setNow(Date.now()),
      () => expiry,
    );
  }, [rows.length, expiry]);
  return rows;
}

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
      {/* However many chats, it draws the rows that can show: ChildSessionRows windows them (WindowedRows). */}
      <ChildSessionRows sessions={rows.map(alsoHereRow)} onOpen={onOpen} />
    </ul>
  );
}
