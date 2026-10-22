// What a chat has produced so far, read from its transcript's tool calls: the pull requests it
// opened, the files it wrote, its subagents, the wakeups it scheduled and the web pages it
// read. The summary card lists them (SummaryCard.tsx, SummaryBody.tsx).
import { turnFiles, type TurnFile } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isSubagentGroup } from "../subagents/subagentRows";
import { transcriptPullRequests, type SummaryPullRequest } from "./transcriptPullRequests";

export type { PullRequestState, SummaryPullRequest } from "./transcriptPullRequests";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type SummarySubagent = { id: string; title: string; state: "running" | "done" | "failed" };
export type SummaryWakeup = { id: string; text: string; cron?: string };
export type SummarySource = { url?: string; label: string };
export type SummaryBackgroundTask = {
  id: string;
  command: string;
  /// What the call says it does (Claude's Bash `description`), when it says.
  description?: string;
  state: "running" | "completed" | "failed" | "stopped";
  /// When its call started (epoch ms), for its elapsed time; absent for one known from its end only.
  startedAt?: number;
};
export type SessionSummary = {
  scheduled: SummaryWakeup[];
  pullRequests: SummaryPullRequest[];
  outputs: TurnFile[];
  subagents: SummarySubagent[];
  sources: SummarySource[];
  backgroundTasks: SummaryBackgroundTask[];
};

const URL = /https?:\/\/[^\s"'<>)]+/;

const tools = (rows: readonly AcpmuxRow[]): Tool[] =>
  rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : []));

/// The session's own subagents, from its subagent groups (subagents/subagentFold.ts); records
/// from before acpmux reported subagents carry Claude's Task tool as a `think` tool call titled
/// with the subagent's description instead.
function subagents(rows: readonly AcpmuxRow[], all: readonly Tool[]): SummarySubagent[] {
  const grouped = rows
    .filter(isSubagentGroup)
    .flatMap((row) => row.subagents ?? [])
    .map((agent): SummarySubagent => ({
      id: agent.id,
      title: agent.name,
      state: agent.state === "running" ? "running" : agent.state === "completed" ? "done" : "failed",
    }));
  const tasks = all
    .filter((tool) => tool.kind === "think" && tool.title.trim() !== "")
    .map((tool): SummarySubagent => ({
      id: tool.id,
      title: tool.title,
      state: tool.status === "completed" ? "done" : tool.status === "failed" ? "failed" : "running",
    }));
  return [...grouped, ...tasks];
}

/// A tool call's input: `inputSummary` carries its `rawInput` as JSON.
function input(tool: Tool): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(tool.inputSummary ?? "");
    return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

const field = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);

/// Wakeups and cron jobs the agent scheduled for itself (Claude's ScheduleWakeup and CronCreate),
/// named by their reason or prompt, with a cron job's schedule.
function scheduled(all: readonly Tool[]): SummaryWakeup[] {
  return all
    .filter((tool) => /^(ScheduleWakeup|CronCreate)\b/.test(tool.title) && tool.status !== "failed")
    .map((tool) => {
      const fields = input(tool);
      return {
        id: tool.id,
        text: field(fields.reason) ?? field(fields.prompt) ?? tool.title,
        cron: field(fields.cron),
      };
    });
}

/// Pages fetched and searches run, once each, in the order first read.
function sources(all: readonly Tool[]): SummarySource[] {
  const seen = new Map<string, SummarySource>();
  for (const tool of all) {
    if (tool.kind !== "fetch") continue;
    const text = `${tool.title} ${tool.inputSummary ?? ""}`;
    const url = URL.exec(text)?.[0];
    const label = url ? url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "") : tool.title;
    const key = url ?? label;
    if (!seen.has(key)) seen.set(key, { url, label });
  }
  return [...seen.values()];
}

/// The pull requests the chat opened (the composer's PR bars, PullRequestDock.tsx).
export const sessionPullRequests = (rows: readonly AcpmuxRow[]) =>
  transcriptPullRequests(rows).filter((pr) => pr.opened);

/// How background shells ended: on their call (`background`, direct.ts `markBackgroundCall`), or
/// in a background task row when the call is not in the transcript.
const backgroundEnds = (
  row: AcpmuxRow,
): { toolCallId: string; command: string; state: SummaryBackgroundTask["state"] }[] =>
  row.backgroundTask
    ? [row.backgroundTask]
    : row.kind === "activity"
      ? (row.items ?? []).flatMap(({ tool }) =>
          tool?.background && tool.background.state !== "running"
            ? [{ toolCallId: tool.id, command: tool.command ?? tool.title, state: tool.background.state }]
            : [],
        )
      : [];

/// Shells the agent ran in the background (Claude's Bash `run_in_background`, or a call it moved
/// there, cx-ncc.84): running until their call or a background task row says how they ended.
function backgroundTasks(rows: readonly AcpmuxRow[], all: readonly Tool[]): SummaryBackgroundTask[] {
  const ends = rows.flatMap(backgroundEnds);
  const ended = new Map(ends.map((end) => [end.toolCallId, end.state] as const));
  const launched = all
    // Shell calls only: a subagent's Agent call can run in the background too.
    .filter((tool) => tool.kind === "execute" && (input(tool).run_in_background === true || !!tool.background))
    .map((tool): SummaryBackgroundTask => ({
      id: tool.id,
      command: field(input(tool).command) ?? tool.title,
      ...(field(input(tool).description) ? { description: field(input(tool).description) } : {}),
      state: ended.get(tool.id) ?? (tool.status === "failed" ? "failed" : "running"),
      ...(tool.startedAt !== undefined ? { startedAt: tool.startedAt } : {}),
    }));
  // A shell whose Bash row is not loaded (an older page, or one Claude moved to the background
  // itself) is known from its end.
  const seen = new Set(launched.map((task) => task.id));
  const endedOnly = ends
    .filter((end) => !seen.has(end.toolCallId))
    .map((end): SummaryBackgroundTask => ({ id: end.toolCallId, command: end.command, state: end.state }));
  return [...launched, ...endedOnly];
}

/// The chat's background shells still running (the running turn's line counts them, WorkingFor.tsx).
export const runningBackgroundTasks = (rows: readonly AcpmuxRow[]) =>
  backgroundTasks(rows, tools(rows)).filter((task) => task.state === "running");

/// What the chat made. With `repository` (the chat folder's `owner/name`, or null when it has
/// none), the Inspector's Changes: its pull requests include the ones the agent only named in a
/// reply, a bare `#N` in that repository among them; without it, only the ones it opened or touched.
export function sessionSummary(rows: readonly AcpmuxRow[], repository?: string | null): SessionSummary {
  const all = tools(rows);
  const inspector = repository !== undefined;
  // The summary card reads only the commands, and lists no mention.
  const pullRequests = transcriptPullRequests(rows, { folder: repository ?? undefined, replies: inspector });
  return {
    scheduled: scheduled(all),
    pullRequests: inspector ? pullRequests : pullRequests.filter((pr) => !pr.mentioned),
    outputs: turnFiles(rows as AcpmuxRow[]),
    subagents: subagents(rows, all),
    sources: sources(all),
    backgroundTasks: backgroundTasks(rows, all),
  };
}

export const isEmptySummary = (summary: SessionSummary) =>
  Object.values(summary).every((list: unknown[]) => list.length === 0);
