// The agent dot grid's model: one dot per listed chat, its state from the same rule as the sidebar's
// row mark (sessionMark, from acpmux's `indicator`, which the daemon decides). No state of its own.
import { listed, sessionMark, sessionTitle, type AcpmuxSessionEntry } from "../sessionList";
import type { StringKey } from "../i18n";

export type DotState = "running" | "approval" | "done" | "error" | "idle";

/** Legend order: what needs the person first, then what is going on. */
export const DOT_STATES: readonly DotState[] = ["approval", "error", "running", "done", "idle"];

export const DOT_LABELS = {
  running: "dotGrid.running",
  approval: "dotGrid.approval",
  done: "dotGrid.done",
  error: "dotGrid.error",
  idle: "dotGrid.idle",
} as const satisfies Record<DotState, StringKey>;

export type AgentDot = { sessionId: string; title: string; state: DotState };

/** A chat's dot: done stays marked until the person opens the chat, as the sidebar's mark does. */
export function dotState(session: AcpmuxSessionEntry): DotState {
  switch (sessionMark(session, false)) {
    case "running":
      return "running";
    case "input":
      return "approval";
    case "error":
      return "error";
    case "unread":
      return "done";
    default:
      return "idle";
  }
}

/** The listed chats as dots, in the order the list gives them, so a dot keeps its place when its state changes. */
export function agentDots(sessions: readonly AcpmuxSessionEntry[], title = sessionTitle): AgentDot[] {
  const dots: AgentDot[] = [];
  const seen = new Set<string>();
  for (const session of sessions) {
    if (!listed(session) || seen.has(session.sessionId)) continue;
    seen.add(session.sessionId);
    dots.push({ sessionId: session.sessionId, title: title(session), state: dotState(session) });
  }
  return dots;
}

/** How many dots are in each state, for the grid's accessible summary and the legend. */
export function dotCounts(dots: readonly AgentDot[]): Record<DotState, number> {
  const counts: Record<DotState, number> = { running: 0, approval: 0, done: 0, error: 0, idle: 0 };
  for (const dot of dots) counts[dot.state] += 1;
  return counts;
}
