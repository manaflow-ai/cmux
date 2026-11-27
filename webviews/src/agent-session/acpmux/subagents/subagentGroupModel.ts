import { createContext, useContext, useCallback, useSyncExternalStore } from "react";
import { usePageNow, subscribePageDeadline } from "../../../ui/pageClock";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "../conversation/turns";
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
  // One acpmux lost (its harness went away, its outcome unknown) ended: it reads Stopped, never
  // "Disconnected", a link state the person can do nothing about (Leo, 2026-11-14, asked
  // connectivity to stay quiet). Its row offers Resume or Restart where acpmux can.
  disconnected: "subagents.state.stopped",
} as const;

/// Milliseconds a subagent has run: until it ended, or until `now`.
/// One waiting on background work of its own has not ended: its time keeps going.
export const elapsed = (agent: Subagent, now: number) =>
  Math.max(0, (awaitsOwnWork(agent) ? now : (agent.endedAt ?? now)) - agent.startedAt);

/// A subagent's time as its lines and cards say it: its own run, from real start and end times. An
/// ended one whose start and end are one moment (an end acpmux recovered for a run whose start the
/// chat never read) has no known time: none, never "0s" (Leo, 2026-11-22, on a card reading
/// "Disconnected · 0s" after a restart). A running one counts up from 0s.
export function subagentTime(agent: Subagent, now: number): string | undefined {
  const ms = elapsed(agent, now);
  return ms < 1000 && !ticking(agent) ? undefined : formatDuration(ms);
}

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

/// For status changes such as becoming idle, wake at a boundary instead of on elapsed seconds.
/// Boundaries use session time and are in ascending order.
export function useSessionBoundary(boundaries: readonly number[]): number {
  const offset = useContext(SubagentClockContext);
  const position = useCallback(() => {
    const now = Date.now() - offset;
    let lo = 0;
    let hi = boundaries.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (boundaries[mid]! <= now) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }, [boundaries, offset]);
  const subscribe = useCallback(
    (notify: () => void) => {
      const next = () => (boundaries[position()] ?? Infinity) + offset;
      return Number.isFinite(next()) ? subscribePageDeadline(notify, next) : () => {};
    },
    [boundaries, offset, position],
  );
  const index = useSyncExternalStore(subscribe, position, position);
  return boundaries[index - 1] ?? -Infinity;
}
