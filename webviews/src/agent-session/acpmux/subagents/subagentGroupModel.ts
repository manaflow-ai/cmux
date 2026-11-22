import { createContext, useContext } from "react";
import { usePageNow } from "../../../ui/pageClock";
import type { AcpmuxRow } from "../model";
import { awaitsOwnWork, type Subagent } from "./subagentFold";

/// The chat's harness (claude, codex, ...): its subagents run on it, so their avatars carry its mark.
export const SubagentHarnessContext = createContext<string | undefined>(undefined);

/// A subagent's own transcript (the snapshot's `subagentViews`), read when a line needs its whole
/// final reply (SubagentReportLine.tsx): a getter, so a streaming view wakes no line (App.tsx).
export const SubagentViewsContext = createContext<((id: string) => readonly AcpmuxRow[] | undefined) | undefined>(
  undefined,
);

/// Opens a subagent's own view in the pane, or the session's own with undefined (App.tsx).
export const SubagentNavContext = createContext<((id: string | undefined) => void) | undefined>(undefined);

/// Shows a subagent in a pane of its own right of the chat while the summary card's switch is on,
/// else in this pane (App.tsx, subagentPanes.ts). A group's subagent line uses it; the child view's pill goes back
/// in place.
export const SubagentPaneContext = createContext<((id: string) => void) | undefined>(undefined);

/// Stops a running subagent (App.tsx, direct.ts `stopSubagent`), settling with Claude's answer;
/// absent where the harness cannot.
export const SubagentStopContext = createContext<((id: string) => Promise<unknown>) | undefined>(undefined);

/// Avatars drawn before "+N".
export const STACK = 3;

export const running = (agent: Subagent) => agent.state === "running";

/// Each subagent state's label in an open group.
export const STATE_LABEL = {
  running: "subagents.state.running",
  completed: "subagents.state.completed",
  failed: "subagents.state.failed",
  cancelled: "subagents.state.cancelled",
  disconnected: "subagents.state.disconnected",
} as const;

/// Milliseconds a subagent has run: until it ended, or until `now`.
/// One waiting on background work of its own has not ended: its time keeps going.
export const elapsed = (agent: Subagent, now: number) =>
  Math.max(0, (awaitsOwnWork(agent) ? now : (agent.endedAt ?? now)) - agent.startedAt);

/// Whether a subagent's clock still runs: running, or waiting on background work of its own.
export const ticking = (agent: Subagent) => running(agent) || awaitsOwnWork(agent);

/// The group's time: from its first start to its last end, or to `now` while one runs.
export function groupElapsed(agents: readonly Subagent[], now: number): number {
  if (agents.length === 0) return 0;
  const start = Math.min(...agents.map((agent) => agent.startedAt));
  // One waiting on background work of its own still counts: its time keeps going (`elapsed`).
  const end = agents.some(ticking) ? now : Math.max(...agents.map((agent) => agent.endedAt ?? agent.startedAt));
  return Math.max(0, end - start);
}

/// The session's clock against this computer's (the snapshot's `clockOffsetMs`: this computer's
/// clock minus the session's; a peer runs on its own). A subagent's times are the session's.
export const SubagentClockContext = createContext(0);

/// The current time on the session's clock (SubagentClockContext), ticking each second only
/// while `live`, so it counts against the subagents' own start and end times. A hidden pane's
/// clock rests (the tray above the composer, a group card and the summary rows tick with it) and
/// catches up the moment the pane shows again.
export function useNow(live: boolean): number {
  const offset = useContext(SubagentClockContext);
  const now = usePageNow(live);
  return now - offset;
}
