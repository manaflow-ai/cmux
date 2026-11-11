// The names this chat's `start_session` calls gave the sub-sessions they started (taskLines.ts
// `startedTasks`), by session id. A message sent to a sub-session (SubsessionCallCard.tsx SentLine)
// names it from the session list while the list has it; once the chat leaves the list, its start
// call still names it, so the row never falls back to a bare id (Leo, 2026-11-03, on a "Sent to"
// row that showed one). The pane works it out once per snapshot from the rows that changed, as
// turnChanges/sessionRows.ts does for edits, and hands the same map on while no start was added.
import { keptPrefix } from "./prefixFlatMap";
import { createContext, createElement, useContext, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { SubsessionContext, type Subsessions } from "../subagents/subsessions";
import { startedTasks } from "./taskLines";

export type StartedNames = { rows: readonly AcpmuxRow[]; names: ReadonlyMap<string, string> };

const NONE: ReadonlyMap<string, string> = new Map();

/// The names `rows`' start calls gave. Rows before the first that differs from `previous.rows` (by
/// object) were read already; `names` stays `previous.names` when no new start names a session.
export function startedNames(rows: readonly AcpmuxRow[], previous?: StartedNames): StartedNames {
  const from = previous ? keptPrefix(previous.rows, rows) : 0;
  // A row before `from` that changed would be a different object, so the prefix is what was read.
  // A row that went away (history trimmed) leaves its name: the session it named is the same.
  let names = previous?.names ?? NONE;
  for (const task of startedTasks(rows.slice(from))) {
    // The first start call that named a session keeps naming it, as `startedTasks` reads them.
    if (!task.name || names.has(task.sessionId)) continue;
    if (names === previous?.names || names === NONE) names = new Map(names);
    (names as Map<string, string>).set(task.sessionId, task.name);
  }
  return { rows, names };
}

export const StartedNamesContext = createContext<ReadonlyMap<string, string>>(NONE);

/// The name the start call of sub-session `sessionId` gave it, if this chat has one.
export function useStartedName(sessionId: string): string | undefined {
  return useContext(StartedNamesContext).get(sessionId);
}

/// The session list's sub-sessions and the names this chat's start calls gave them, in one element,
/// so the pane's provider tree keeps its depth.
export function SubsessionNamesProvider({
  subsessions,
  started,
  children,
}: {
  subsessions: Subsessions;
  started: ReadonlyMap<string, string>;
  children: ReactNode;
}) {
  return createElement(
    SubsessionContext.Provider,
    { value: subsessions },
    createElement(StartedNamesContext.Provider, { value: started }, children),
  );
}
