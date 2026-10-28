import { sessionEntry, type SessionPullRequest } from "../sessionList";
import type { WorkflowAgent } from "./workflow";

/** A session-list/watch row, or one match returned by `_acpmux/resolve`. */
export type TrackingSessionRecord = { sessionId: string } & Record<string, unknown>;

/** Context for the existing WorkflowAgentRow, kept separate from workflow/task identity. */
export type SessionTrackingRow = {
  agent: WorkflowAgent;
  sessionId: string;
  qualifiedSessionId?: string;
  host?: string;
  area?: string;
  sourceState?: string;
  stuckReason?: string;
  /** The session folder's branch PR, only when the daemon supplies it. */
  currentPullRequest?: SessionPullRequest;
  /** Recorded PRs are history, not proof that any one is still current or open. */
  pullRequests: string[];
};

type TrackingOptions = {
  /** This daemon's host from connection metadata; no local hostname is invented. */
  localHost?: string;
  /** Matches from resolve, on this same daemon. Never resolve or join by display name. */
  resolved?: readonly TrackingSessionRecord[];
};

const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);
const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const timestamp = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

function hostOf(session: TrackingSessionRecord, localHost?: string): string | undefined {
  return text(session.peer) ?? text(session.host) ?? text(localHost);
}

function identity(session: TrackingSessionRecord, localHost?: string): string {
  const qualified = text(session.qualifiedSessionId);
  return qualified
    ? JSON.stringify([qualified])
    : JSON.stringify([hostOf(session, localHost) ?? null, session.sessionId]);
}

/** Preserve transport uncertainty even when the last mirrored lane still says working. */
function sourceState(session: TrackingSessionRecord, explicitState?: string): string | undefined {
  const status = text(session.status);
  if (session.stale === true || status === "unreachable" || status === "disconnected") return "unreachable";
  if (status === "closed") return "closed";
  return explicitState ?? text(record(session.lane)?.state) ?? status;
}

/** Idle/closed sessions do not prove a task completed; unknown never inflates completed counts. */
function workflowState(state: string | undefined): WorkflowAgent["state"] {
  switch (state) {
    case "working":
    case "running":
      return "running";
    case "input":
    case "waiting":
      return "waiting";
    case "pending":
      return "pending";
    case "failed":
    case "lost":
    case "stuck":
      return "failed";
    case "completed":
      return "completed";
    case "paused":
      return "paused";
    case "cancelled":
      return "cancelled";
    default:
      return "unknown";
  }
}

/**
 * Pure projection of a complete daemon session list, including peers, archived and closed rows.
 * Call on list/watch changes, not transcript tokens. No requests, timers, filters or local lane list.
 * Resolve enriches PR history/host only: a delayed resolve never overwrites a fresher list's state.
 */
export function sessionTrackingRows(
  sessions: readonly TrackingSessionRecord[],
  { localHost, resolved = [] }: TrackingOptions = {},
): SessionTrackingRow[] {
  const matches = new Map<string, TrackingSessionRecord | null>();
  for (const match of resolved) {
    const key = identity(match, localHost);
    matches.set(key, matches.has(key) ? null : match);
  }
  return sessions.map((session) => {
    const id = identity(session, localHost);
    const candidate = matches.get(id);
    const resolved = candidate?.sessionId === session.sessionId ? candidate : undefined;
    const entry = sessionEntry(session);
    const state = sourceState(session, entry.trackingState);
    const lane = record(session.lane);
    const stuckReason = state === "stuck" ? entry.stuckReason : undefined;
    const reason = stuckReason ?? (state === "failed" || state === "lost" ? text(lane?.error) : undefined);
    const turn = record(session.turn);
    const startedAt = state === "working" || state === "running" ? timestamp(turn?.startedAt) : undefined;
    const resolvedEntry = resolved ? sessionEntry(resolved) : undefined;
    const urls = Object.hasOwn(session, "pullRequests") ? entry.pullRequestUrls : resolvedEntry?.pullRequestUrls;
    const pullRequests = [...new Set(urls ?? [])];
    return {
      agent: {
        id,
        name: text(session.name) ?? session.sessionId,
        state: workflowState(state),
        model: entry.model,
        doing: state === "working" || state === "running" ? entry.doing : undefined,
        retryReason: reason,
        startedAt,
        // A session ID is not a Claude subagent transcript ID. Keep agentId unset.
      },
      sessionId: session.sessionId,
      qualifiedSessionId: text(session.qualifiedSessionId),
      host: hostOf(session, localHost) ?? (resolved ? hostOf(resolved) : undefined),
      area: entry.area,
      sourceState: state,
      stuckReason,
      currentPullRequest: entry.pullRequest,
      pullRequests,
    };
  });
}
