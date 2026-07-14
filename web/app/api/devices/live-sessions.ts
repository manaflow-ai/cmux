const MAX_LIVE_SESSIONS_PER_INSTANCE = 50;
const MAX_ID_LENGTH = 128;
const MAX_TITLE_LENGTH = 160;
const MAX_AGENT_LENGTH = 32;
const MAX_LAST_ACTIVITY_AT = 253_402_300_799; // 9999-12-31T23:59:59Z
const LIVE_SESSION_STATUSES = new Set(["working", "needs_input", "idle", "ended"]);

export type RegistryLiveSession = {
  id: string;
  workspaceID: string;
  terminalID?: string;
  agentSessionID?: string;
  title: string;
  agent?: string;
  status: "working" | "needs_input" | "idle" | "ended";
  lastActivityAt: number;
};

function boundedString(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.slice(0, maxLength);
}

/**
 * Sanitize the best-effort live-session advertisement stored in instance
 * labels. The registry carries only bounded summaries; transcripts, prompts,
 * terminal output, and credentials are never accepted into this surface.
 */
export function sanitizeLiveSessions(value: unknown): RegistryLiveSession[] {
  if (!Array.isArray(value)) return [];

  const byID = new Map<string, RegistryLiveSession>();
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) continue;
    const record = candidate as Record<string, unknown>;
    const id = boundedString(record.id, MAX_ID_LENGTH);
    const workspaceID = boundedString(record.workspaceID, MAX_ID_LENGTH);
    const title = boundedString(record.title, MAX_TITLE_LENGTH);
    const status = boundedString(record.status, 32);
    const lastActivityAt = record.lastActivityAt;
    if (
      !id ||
      !workspaceID ||
      !title ||
      !status ||
      !LIVE_SESSION_STATUSES.has(status) ||
      typeof lastActivityAt !== "number" ||
      !Number.isFinite(lastActivityAt) ||
      lastActivityAt < 0 ||
      lastActivityAt > MAX_LAST_ACTIVITY_AT
    ) {
      continue;
    }

    const session: RegistryLiveSession = {
      id,
      workspaceID,
      title,
      status: status as RegistryLiveSession["status"],
      lastActivityAt,
    };
    const terminalID = boundedString(record.terminalID, MAX_ID_LENGTH);
    const agentSessionID = boundedString(record.agentSessionID, MAX_ID_LENGTH);
    const agent = boundedString(record.agent, MAX_AGENT_LENGTH);
    if (terminalID) session.terminalID = terminalID;
    if (agentSessionID) session.agentSessionID = agentSessionID;
    if (agent) session.agent = agent;
    byID.set(id, session);
  }

  return [...byID.values()]
    .sort((lhs, rhs) => rhs.lastActivityAt - lhs.lastActivityAt)
    .slice(0, MAX_LIVE_SESSIONS_PER_INSTANCE);
}

/** Store live sessions under a reserved instance-label key without trusting a client copy. */
export function labelsWithLiveSessions(
  labels: Record<string, unknown>,
  sessions: unknown,
): Record<string, unknown> {
  const { liveSessions: _ignored, ...unreserved } = labels;
  void _ignored;
  return { ...unreserved, liveSessions: sanitizeLiveSessions(sessions) };
}

/** Read and re-sanitize the reserved live-session label before returning it. */
export function liveSessionsFromLabels(labels: Record<string, unknown>): RegistryLiveSession[] {
  return sanitizeLiveSessions(labels.liveSessions);
}

/** Hide the reserved storage detail from the public instance-label bag. */
export function publicInstanceLabels(labels: Record<string, unknown>): Record<string, unknown> {
  const { liveSessions: _sessions, ...publicLabels } = labels;
  void _sessions;
  return publicLabels;
}
