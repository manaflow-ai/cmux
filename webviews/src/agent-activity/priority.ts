import type { SessionChanged, SessionSummary } from "../agent-session/acpmux/protocol/generated/types";
import type { Lane, LaneState } from "./lanes";

/** The small event envelope emitted by the ACPmux watch hook. */
export type AgentStateEvent = {
  kind: "created" | "updated" | "purged";
  sessionId: string;
  seq: number;
  session?: SessionSummary;
  /** Existing native sessionId → workspace binding. */
  workspaceId?: string | null;
  peer?: string | null;
};

export type PriorityState = {
  lanes: Lane[];
  /** Last hook sequence applied, per session, for duplicate/out-of-order defense. */
  seqBySession: Record<string, number>;
};

function laneState(session: SessionSummary): LaneState {
  if (session.lane?.state) return session.lane.state;
  if (session.status === "waiting" || session.pendingPermissions > 0) return "input";
  if (session.status === "running") return "working";
  if (session.status === "unreachable" || session.status === "disconnected") return "lost";
  if (session.status === "closed") return "lost";
  return "idle";
}

function laneFor(session: SessionSummary, workspaceId: string | null | undefined, peer?: string | null): Lane {
  const state = laneState(session);
  const since = session.lane?.since ?? session.inputSince ?? session.updatedAt;
  const error = session.lastTurn?.errorText ?? session.lastTurn?.detail ?? null;
  return {
    id: session.sessionId,
    name: session.name || session.sessionId,
    title: session.title || session.lastPrompt || session.name || session.sessionId,
    parent: session.parentId ?? session.spawnedBy ?? null,
    peer: peer ?? session.peer ?? null,
    workspaceId: workspaceId ?? null,
    state,
    since,
    error: state === "failed" ? error : null,
  };
}

/** Convert the ACPmux watch payload without inventing a second identity model. */
export function agentStateEvent(change: SessionChanged, workspaceId?: string | null): AgentStateEvent {
  return {
    kind: change.kind === "purged" ? "purged" : change.kind === "created" ? "created" : "updated",
    sessionId: change.sessionId,
    seq: change.seq,
    session: change.session && typeof change.session.status === "string" ? change.session : undefined,
    workspaceId,
    peer: change.peer,
  };
}

export function applyAgentStateEvent(state: PriorityState, event: AgentStateEvent): PriorityState {
  if (event.seq <= (state.seqBySession[event.sessionId] ?? -1)) return state;
  const nextSeqBySession = { ...state.seqBySession, [event.sessionId]: event.seq };
  const previous = state.lanes.find((lane) => lane.id === event.sessionId);
  const existing = state.lanes.filter((lane) => lane.id !== event.sessionId);
  if (event.kind === "purged" || !event.session) return { lanes: existing, seqBySession: nextSeqBySession };
  return {
    lanes: [
      ...existing,
      laneFor(event.session, event.workspaceId ?? previous?.workspaceId, event.peer ?? previous?.peer),
    ],
    seqBySession: nextSeqBySession,
  };
}

export function priorityLanes(state: PriorityState): Lane[] {
  return [...state.lanes].sort((a, b) => {
    const rank: Record<LaneState, number> = { failed: 0, lost: 1, input: 2, idle: 3, working: 4 };
    return rank[a.state] - rank[b.state] || (a.since ?? 0) - (b.since ?? 0) || a.id.localeCompare(b.id);
  });
}

export const initialPriorityState = (): PriorityState => ({ lanes: [], seqBySession: {} });
