import {
  adapterOrder,
  adapters,
  buildResumeCommand,
  compareAdapters,
  normalizeAdapterId,
  shellQuote,
  type AdapterId,
} from "./adapters";

export const statusOrder = ["awaiting", "working", "completed"] as const;

export type SessionStatus = (typeof statusOrder)[number];

export interface HomeSession {
  id: string;
  adapter: AdapterId;
  sessionId?: string;
  status: SessionStatus;
  title: string;
  cwd?: string;
  branch?: string;
  updatedAt?: string;
  preview?: string;
  details?: string;
  task?: string;
  resumeCommand?: string;
}

export interface HomeState {
  generatedAt?: string;
  sessions: HomeSession[];
}

export interface GroupedSessions {
  status: SessionStatus;
  sessions: HomeSession[];
}

interface SessionContext {
  cwd?: string;
  branch?: string;
  task?: string;
}

export function parseHomeState(raw: unknown): HomeState {
  validateSchemaContract(raw);
  const root = recordValue(raw);
  const generatedAt = stringValue(root?.generatedAt ?? root?.generated_at ?? root?.updatedAt ?? root?.updated_at);
  const rawSessions = collectRawSessions(raw);
  const sessions = rawSessions
    .map(({ value, context }, index) => parseSession(value, index, context))
    .filter((session): session is HomeSession => Boolean(session))
    .sort(compareSessions);
  return { generatedAt, sessions };
}

export function createFallbackState(): HomeState {
  return parseHomeState({
    generatedAt: "2026-01-01T00:00:00.000Z",
    sessions: [
      {
        id: "claude-plan",
        adapter: "claude",
        sessionId: "claude-session-123",
        status: "awaiting",
        title: "Review plan for terminal notifications",
        cwd: "/Users/example/cmux",
        branch: "feat-agent-home",
        preview: "Claude is waiting for plan approval.",
        details: "Prototype row that mirrors a cmux Feed plan/permission stop.",
      },
      {
        id: "codex-fix",
        adapter: "codex",
        sessionId: "codex-session-456",
        status: "working",
        title: "Implement grouped home state parser",
        cwd: "/Users/example/cmux",
        branch: "feat-agent-home",
        preview: "Codex is editing the TypeScript prototype.",
      },
      {
        id: "opencode-completed",
        adapter: "opencode",
        sessionId: "opencode-session-789",
        status: "completed",
        title: "Investigate OpenCode resume",
        cwd: "/Users/example/cmux",
        preview: "OpenCode has a resumable session.",
      },
      {
        id: "pi-completed",
        adapter: "pi",
        sessionId: "pi-session-101",
        status: "completed",
        title: "Sketch Vault registry bridge",
        cwd: "/Users/example/cmux",
        preview: "Pi finished its first pass.",
      },
    ],
  });
}

export function groupSessionsByStatus(sessions: HomeSession[]): GroupedSessions[] {
  return statusOrder.map((status) => ({
    status,
    sessions: sessions.filter((session) => session.status === status).sort(compareSessions),
  }));
}

export function adapterCounts(sessions: HomeSession[]): Record<AdapterId, number> {
  const counts = Object.fromEntries(adapterOrder.map((adapter) => [adapter, 0])) as Record<AdapterId, number>;
  for (const session of sessions) {
    counts[session.adapter] += 1;
  }
  return counts;
}

export function statusCounts(sessions: HomeSession[]): Record<SessionStatus, number> {
  const counts = Object.fromEntries(statusOrder.map((status) => [status, 0])) as Record<SessionStatus, number>;
  for (const session of sessions) {
    counts[session.status] += 1;
  }
  return counts;
}

export function compareSessions(left: HomeSession, right: HomeSession): number {
  const statusDelta = statusOrder.indexOf(left.status) - statusOrder.indexOf(right.status);
  if (statusDelta !== 0) {
    return statusDelta;
  }
  const adapterDelta = compareAdapters(left.adapter, right.adapter);
  if (adapterDelta !== 0) {
    return adapterDelta;
  }
  const updatedDelta = timestamp(right.updatedAt) - timestamp(left.updatedAt);
  if (updatedDelta !== 0) {
    return updatedDelta;
  }
  const titleDelta = left.title.localeCompare(right.title);
  if (titleDelta !== 0) {
    return titleDelta;
  }
  return left.id.localeCompare(right.id);
}

function parseSession(raw: unknown, index: number, context: SessionContext): HomeSession | undefined {
  const record = recordValue(raw);
  if (!record) {
    return undefined;
  }

  const agentRecord = recordValue(record.agent);
  const terminalRecord = recordValue(record.terminal);
  const terminalAgentRecord = recordValue(terminalRecord?.agent);
  const merged = {
    ...terminalAgentRecord,
    ...agentRecord,
    ...record,
  };

  const adapter = normalizeAdapterId(
    merged.adapter ?? merged.agent ?? merged.source ?? merged.kind ?? merged.agentKind ?? merged.agent_kind,
  );
  if (!adapter) {
    return undefined;
  }

  const sessionId = stringValue(
    merged.agentSessionId
      ?? merged.sessionId
      ?? merged.agent_session_id
      ?? merged.session_id
      ?? merged.nativeSessionId
      ?? merged.native_session_id
      ?? merged.chatId,
  );
  const id = stringValue(merged.id ?? merged.panelId ?? merged.surfaceId ?? merged.workspaceId)
    ?? `${adapter}-${sessionId ?? index + 1}`;
  const cwd = stringValue(
    merged.cwd
      ?? merged.workingDirectory
      ?? merged.working_directory
      ?? merged.workspacePath
      ?? recordValue(merged.workspace)?.cwd
      ?? context.cwd,
  );
  const title = stringValue(merged.title ?? merged.name ?? merged.summary ?? merged.task ?? merged.prompt)
    ?? `${adapters[adapter].displayName} session`;
  const workspaceGit = recordValue(recordValue(merged.workspace)?.git);
  const activity = recordValue(merged.activity);
  const attention = recordValue(merged.attention);
  const resume = recordValue(merged.resume);
  const status = normalizeStatus(merged.status ?? merged.state ?? merged.phase ?? activity?.phase);
  const resumeCommand = stringValue(merged.resumeCommand ?? merged.resume_command)
    ?? commandArrayValue(resume?.command)
    ?? buildResumeCommand({
      adapter,
      sessionId,
      cwd,
      model: stringValue(merged.model ?? merged.providerModel ?? merged.provider_model),
      permissionMode: stringValue(merged.permissionMode ?? merged.permission_mode),
      approvalPolicy: stringValue(merged.approvalPolicy ?? merged.approval_policy),
      sandboxMode: stringValue(merged.sandboxMode ?? merged.sandbox_mode),
      effort: stringValue(merged.effort ?? merged.reasoningEffort ?? merged.reasoning_effort),
      agentName: stringValue(merged.agentName ?? merged.agent_name),
      thinking: stringValue(merged.thinking),
    });

  return {
    id,
    adapter,
    sessionId,
    status,
    title,
    cwd,
    branch: stringValue(merged.gitBranch ?? merged.git_branch ?? merged.branch ?? workspaceGit?.branch ?? context.branch),
    updatedAt: dateString(merged.updatedAt ?? merged.updated_at ?? merged.modified ?? merged.modifiedAt),
    preview: stringValue(
      merged.preview
        ?? merged.lastMessage
        ?? merged.last_message
        ?? activity?.lastMessage
        ?? attention?.promptSummary
        ?? merged.message
        ?? merged.notification,
    ),
    details: stringValue(merged.details ?? merged.detail ?? merged.summary ?? merged.description ?? merged.transcriptSummary),
    task: stringValue(merged.task ?? merged.currentTask ?? merged.current_task ?? context.task),
    resumeCommand,
  };
}

function collectRawSessions(raw: unknown): Array<{ value: unknown; context: SessionContext }> {
  if (Array.isArray(raw)) {
    return raw.map((value) => ({ value, context: {} }));
  }

  const root = recordValue(raw);
  if (!root) {
    return [];
  }

  const direct = arrayValue(root.sessions)
    ?? arrayValue(recordValue(root.home)?.sessions)
    ?? arrayValue(recordValue(root.state)?.sessions)
    ?? arrayValue(recordValue(root.cmuxHome)?.sessions);
  if (direct) {
    return direct.map((value) => ({ value, context: {} }));
  }

  const workspaces = arrayValue(root.workspaces ?? root.tabs ?? root.panes);
  if (!workspaces) {
    return [];
  }

  const collected: Array<{ value: unknown; context: SessionContext }> = [];
  for (const workspace of workspaces) {
    const workspaceRecord = recordValue(workspace);
    const context: SessionContext = {
      cwd: stringValue(workspaceRecord?.cwd ?? workspaceRecord?.workingDirectory ?? workspaceRecord?.path),
      branch: stringValue(workspaceRecord?.gitBranch ?? workspaceRecord?.git_branch ?? workspaceRecord?.branch),
      task: stringValue(workspaceRecord?.task ?? workspaceRecord?.currentTask),
    };
    const nested = [
      ...(arrayValue(workspaceRecord?.sessions) ?? []),
      ...(arrayValue(workspaceRecord?.panels) ?? []),
      ...(arrayValue(workspaceRecord?.surfaces) ?? []),
      ...(arrayValue(workspaceRecord?.tabs) ?? []),
    ];
    for (const value of nested) {
      collected.push({ value, context });
    }
  }
  return collected;
}

function normalizeStatus(value: unknown): SessionStatus {
  if (typeof value !== "string") {
    return "completed";
  }
  const normalized = value.trim().toLowerCase().replace(/[\s-]+/g, "_");
  switch (normalized) {
    case "waiting":
    case "awaiting":
    case "needs_input":
    case "needs_user_input":
    case "awaitinguser":
    case "awaiting_user":
    case "blocked":
    case "pending":
      return "awaiting";
    case "running":
    case "active":
    case "working":
    case "executing":
    case "busy":
    case "in_progress":
      return "working";
    case "idle":
    case "ready":
    case "paused":
    case "stopped":
      return "completed";
    case "done":
    case "complete":
    case "completed":
    case "success":
    case "succeeded":
      return "completed";
    case "failed":
    case "error":
    case "crashed":
    case "cancelled":
    case "canceled":
      return "awaiting";
    default:
      return "completed";
  }
}

function validateSchemaContract(raw: unknown): void {
  const root = recordValue(raw);
  const version = root?.schemaVersion ?? root?.schema_version;
  if (version === undefined) {
    return;
  }
  if (version !== 1) {
    throw new Error("unsupported cmux home schemaVersion, expected 1");
  }
  const sessions = arrayValue(root?.sessions);
  for (const [index, session] of sessions?.entries() ?? []) {
    const status = recordValue(session)?.status;
    if (status !== "awaiting" && status !== "working" && status !== "completed") {
      throw new Error(`sessions[${index}].status must be awaiting, working, or completed`);
    }
  }
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function arrayValue(value: unknown): unknown[] | undefined {
  return Array.isArray(value) ? value : undefined;
}

function commandArrayValue(value: unknown): string | undefined {
  const parts = arrayValue(value);
  const commandParts = parts?.map((part) => typeof part === "string" ? part.trim() : "");
  if (!commandParts || commandParts.some((part) => !part)) {
    return undefined;
  }
  return commandParts.map(shellQuote).join(" ");
}

function stringValue(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed || undefined;
}

function dateString(value: unknown): string | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value > 10_000_000_000 ? value : value * 1_000).toISOString();
  }
  if (typeof value !== "string" || !value.trim()) {
    return undefined;
  }
  const numeric = Number(value);
  if (Number.isFinite(numeric)) {
    return dateString(numeric);
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function timestamp(value: string | undefined): number {
  if (!value) {
    return 0;
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}
