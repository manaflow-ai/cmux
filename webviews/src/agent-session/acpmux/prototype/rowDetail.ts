// Opt-in sidebar row detail (#16688). A workspace row is its title and one mark by default; a user
// who wants more turns it on with `sidebar.rowDetail` and the per-item `sidebar.rowDetailItems`.
// Classic cmux forces the minimal row whatever those say.
import { sessionMark, shortAge, type AcpmuxSessionEntry, type SessionPullRequest } from "../sessionList";
import { workspaceLead, type Workspace } from "./workspaces";

export type RowDetailLevel = "minimal" | "standard" | "everything";
export type RowDetailItem = "preview" | "pullRequest" | "branch" | "agents" | "groupByStatus";
export type RowDetailItems = Record<RowDetailItem, boolean>;

export const ROW_DETAIL_ITEMS: readonly RowDetailItem[] = [
  "preview",
  "pullRequest",
  "branch",
  "agents",
  "groupByStatus",
];

const PRESETS: Record<RowDetailLevel, readonly RowDetailItem[]> = {
  minimal: [],
  standard: ["preview", "pullRequest"],
  everything: ROW_DETAIL_ITEMS,
};

/** What a row shows: the level's preset, then each per-item override. Classic cmux is always minimal. */
export function rowDetailItems(
  level: RowDetailLevel,
  overrides: Partial<RowDetailItems> = {},
  style?: "terminal",
): RowDetailItems {
  const on = new Set(PRESETS[level]);
  const items = Object.fromEntries(
    ROW_DETAIL_ITEMS.map((item) => [item, style !== "terminal" && (overrides[item] ?? on.has(item))]),
  );
  return items as RowDetailItems;
}

/** `minimal`, `standard` or `everything`, else the default (minimal). */
export const rowDetailLevel = (value: unknown): RowDetailLevel =>
  value === "standard" || value === "everything" ? value : "minimal";

export type AgentStatus = "input" | "running" | "error" | "idle";
/** An agent's status in words, for its mark's tooltip and label. */
export const STATUS_WORDS: Record<AgentStatus, string> = {
  input: "needs input",
  running: "working",
  error: "disconnected",
  idle: "idle",
};
export type WorkspaceAgent = { sessionId: string; harness?: string; title: string; status: AgentStatus };
export type WorkspaceDetail = {
  agents: WorkspaceAgent[];
  /** The lead session's latest reply and how long ago it changed. */
  preview?: { text: string; age: string };
  branch?: string;
  pullRequest?: SessionPullRequest;
  status: AgentStatus;
};

const URGENCY: readonly AgentStatus[] = ["input", "running", "error", "idle"];

/** Everything a detailed row could draw for a workspace, from the sessions its agent tabs show. */
export function workspaceDetail(
  workspace: Workspace,
  sessions: ReadonlyMap<string, AcpmuxSessionEntry>,
  now: number,
): WorkspaceDetail {
  const agents = workspace.tabs.flatMap((tab): WorkspaceAgent[] => {
    const session = tab.sessionId ? sessions.get(tab.sessionId) : undefined;
    if (!session) return [];
    const mark = sessionMark(session, true);
    const status = mark && mark !== "unread" ? mark : "idle";
    return [{ sessionId: session.sessionId, harness: session.harness, title: tab.title, status }];
  });
  const leadId = workspaceLead(workspace).sessionId;
  const lead = leadId ? sessions.get(leadId) : undefined;
  return {
    agents,
    preview: lead?.preview ? { text: lead.preview, age: shortAge(lead.updatedAt, now) } : undefined,
    branch: lead?.branch,
    // The lead's pull request, else the first one another agent here opened.
    pullRequest: lead?.pullRequest ?? agents.map((agent) => sessions.get(agent.sessionId)?.pullRequest).find(Boolean),
    status: URGENCY.find((status) => agents.some((agent) => agent.status === status)) ?? "idle",
  };
}

export type StatusGroup<T> = { status: AgentStatus; label: string; items: T[] };

const GROUP_LABELS: Record<AgentStatus, string> = {
  input: "Needs input",
  running: "Working",
  error: "Disconnected",
  idle: "Idle",
};

/** Rows grouped by their most urgent agent, most urgent group first, keeping stack order within a
 * group. Empty groups are left out. */
export function groupByStatus<T>(items: readonly T[], status: (item: T) => AgentStatus): StatusGroup<T>[] {
  return URGENCY.flatMap((key) => {
    const members = items.filter((item) => status(item) === key);
    return members.length ? [{ status: key, label: GROUP_LABELS[key], items: members }] : [];
  });
}
