// What a chat has produced so far, read from its transcript's tool calls: the pull requests it
// opened, the files it wrote, its subagents, the wakeups it scheduled and the web pages it
// read. The summary card lists them (SummaryCard.tsx, SummaryBody.tsx).
import { turnFiles, type TurnFile } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isSubagentGroup } from "../subagents/subagentRows";
import { mcpCall, mcpPlainName } from "../conversation/mcpCalls";
import { editedPaths } from "../toolPaths";
import { transcriptPullRequests, transcriptSummaryVersion, type SummaryPullRequest } from "./transcriptPullRequests";

export type { PullRequestState, SummaryPullRequest } from "./transcriptPullRequests";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type SummarySubagent = { id: string; title: string; state: "running" | "done" | "failed" };
export type SummaryWakeup = { id: string; text: string; cron?: string };
export type SummarySourceKind = "url" | "pullRequest" | "issue" | "file" | "mcp";
export type SummarySource = { url?: string; label: string; kind?: SummarySourceKind };
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
  /// The chat's project folder; absent leaves Outputs unscoped.
  cwd?: string;
  scheduled: SummaryWakeup[];
  pullRequests: SummaryPullRequest[];
  outputs: TurnFile[];
  subagents: SummarySubagent[];
  sources: SummarySource[];
  backgroundTasks: SummaryBackgroundTask[];
};

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

const GITHUB_PR_URL = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)(?:\/[^\s]*)?$/;
const GITHUB_ISSUE_URL = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+)(?:\/[^\s]*)?$/;
const sourceKey = (source: SummarySource) => `${source.kind ?? "url"}:${source.url ?? source.label}`;
let summaryCache:
  | {
      revision: symbol;
      repository?: string | null;
      cwd?: string;
      summary: SessionSummary;
    }
  | undefined;
const normalizedPath = (path: string) => {
  const absolute = path.startsWith("/");
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (parts.length > 0 && parts.at(-1) !== "..") parts.pop();
      else if (!absolute) parts.push(part);
      continue;
    }
    parts.push(part);
  }
  const compact = `${absolute ? "/" : ""}${parts.join("/")}`;
  return compact || (absolute ? "/" : ".");
};

/// Outputs belong to the chat's project folder. Relative tool paths are already rooted there;
/// absolute paths must stay under `cwd`, so scratch files such as `/tmp/m1076.txt` never appear.
export function projectPathAllowed(path: string, cwd?: string): boolean {
  if (!path || path.startsWith("~")) return false;
  if (!path.startsWith("/")) return !path.split("/").includes("..");
  if (!cwd) return false;
  const root = normalizedPath(cwd);
  const normalized = normalizedPath(path);
  if (root === "/") return true;
  return normalized === root || normalized.startsWith(`${root}/`);
}

export function filesInProject(files: readonly TurnFile[], cwd?: string): TurnFile[] {
  return files.filter((file) => projectPathAllowed(file.canonical ?? file.path, cwd));
}

/// Pages, files, MCP calls and read-only PR/issue references, in the order first encountered.
function sources(
  rows: readonly AcpmuxRow[],
  all: readonly Tool[],
  pullRequests: readonly SummaryPullRequest[],
): SummarySource[] {
  const seen = new Map<string, SummarySource>();
  const add = (source: SummarySource) => {
    const key = sourceKey(source);
    if (!seen.has(key)) seen.set(key, source);
  };
  for (const pr of pullRequests)
    if (!pr.changed && !pr.opened) {
      const ambiguous = pr.mentioned && !pr.kind;
      add({
        // GitHub redirects /issues/N to the PR when N is a PR; a bare number proves neither kind.
        url: ambiguous ? `https://github.com/${pr.repo}/issues/${pr.number}` : pr.url,
        label: pr.title ?? (ambiguous ? `${pr.repo}#${pr.number}` : `${pr.repo} #${pr.number}`),
        kind: ambiguous ? "url" : (pr.kind ?? "pullRequest"),
      });
    }
  const knownPullRequests = new Map(pullRequests.map((pr) => [pr.url, pr]));
  const addUrls = (text: string) => {
    for (const match of text.matchAll(/https?:\/\/[^\s"'<>)]+/g)) {
      const url = match[0]!.replace(/[.,;:!?]+$/, "");
      const pr = GITHUB_PR_URL.exec(url);
      if (pr) {
        const canonical = `https://github.com/${pr[1]}/${pr[2]}/pull/${pr[3]}`;
        const known = knownPullRequests.get(canonical);
        if (known?.changed || known?.opened) continue;
        add({
          url: canonical,
          label: known?.title ?? `${pr[1]}/${pr[2]} #${pr[3]}`,
          kind: "pullRequest",
        });
        continue;
      }
      if (GITHUB_ISSUE_URL.test(url)) {
        const issue = GITHUB_ISSUE_URL.exec(url)!;
        const canonical = `https://github.com/${issue[1]}/${issue[2]}/issues/${issue[3]}`;
        const known = knownPullRequests.get(canonical);
        if (known?.changed || known?.opened) continue;
        add({ url, label: url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, ""), kind: "issue" });
      } else {
        add({ url, label: url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, ""), kind: "url" });
      }
    }
  };
  for (const tool of all) {
    if (tool.status !== "completed" || (tool.exitCode ?? 0) !== 0) continue;
    const text = `${tool.title} ${tool.inputSummary ?? ""} ${tool.output ?? ""}`;
    addUrls(text);
    if (tool.kind === "fetch" && !/https?:\/\//.test(text)) add({ label: tool.title });
    if (tool.kind === "read") for (const path of editedPaths(tool)) add({ label: path, kind: "file" });
    const call = mcpCall(tool);
    if (call) add({ label: mcpPlainName(call), kind: "mcp" });
  }
  // Producer revisions keep streamed replies out of this settled scan.
  for (const row of rows) if (row.kind === "assistant" && !row.streaming) addUrls(row.text ?? "");
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
export function sessionSummary(rows: readonly AcpmuxRow[], repository?: string | null, cwd?: string): SessionSummary {
  const producerRevision = transcriptSummaryVersion(rows);
  if (
    producerRevision &&
    summaryCache?.revision === producerRevision &&
    summaryCache.repository === repository &&
    summaryCache.cwd === cwd
  )
    return summaryCache.summary;
  const all = tools(rows);
  const inspector = repository !== undefined;
  // The summary card reads only the commands, and lists no mention.
  const folder = repository ?? undefined;
  const pullRequests = transcriptPullRequests(rows, { folder, replies: inspector });
  const result = {
    ...(cwd ? { cwd } : {}),
    scheduled: scheduled(all),
    pullRequests: inspector ? pullRequests : pullRequests.filter((pr) => !pr.mentioned),
    outputs: cwd === undefined ? turnFiles(rows as AcpmuxRow[]) : filesInProject(turnFiles(rows as AcpmuxRow[]), cwd),
    subagents: subagents(rows, all),
    sources: sources(rows, all, pullRequests),
    backgroundTasks: backgroundTasks(rows, all),
  };
  if (producerRevision) summaryCache = { revision: producerRevision, repository, cwd, summary: result };
  return result;
}

export const isEmptySummary = (summary: SessionSummary) =>
  Object.values(summary).every((value) => !Array.isArray(value) || value.length === 0);
