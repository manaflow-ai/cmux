// What a chat has produced so far, read from its transcript's tool calls: the pull requests it
// opened, the files it wrote, its subagents, the wakeups it scheduled and the web pages it
// read. The summary card lists them (SummaryCard.tsx, SummaryBody.tsx).
import { turnFiles, type TurnFile } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isSubagentGroup } from "../subagents/subagentRows";
import { mcpCall, mcpIsObservational, mcpPlainName } from "../conversation/mcpCalls";
import { editedPaths } from "../toolPaths";
import {
  pullRequestSourceCommand,
  transcriptPullRequests,
  transcriptSummaryVersion,
  type SummaryPullRequest,
} from "./transcriptPullRequests";

export type { PullRequestState, SummaryPullRequest } from "./transcriptPullRequests";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type SummarySubagent = { id: string; title: string; state: "running" | "done" | "failed" };
export type SummaryWakeup = { id: string; text: string; cron?: string };
export type SummarySourceKind = "url" | "pullRequest" | "issue" | "file" | "mcp" | "image";
/// `image`: a pasted image's id in its prompt, and its bytes when the prompt carried them.
export type SummarySource = {
  url?: string;
  label: string;
  kind?: SummarySourceKind;
  image?: { id: string; src?: string };
};
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

const GITHUB_REFERENCE_URL = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/(pull|issues)\/(\d+)(?:\/[^\s]*)?$/;
const sourceKey = (source: SummarySource) => {
  const github = source.url?.match(/^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/(?:pull|issues)\/(\d+)/);
  if (source.image) return `image:${source.image.id}`;
  return github
    ? `github:${github[1]!.toLowerCase()}/${github[2]!.toLowerCase()}#${github[3]}`
    : `${source.kind ?? "url"}:${source.url ?? source.label}`;
};
// Revision ownership lets old summaries go when their producer and snapshots release them.
const summaryCache = new WeakMap<object, { repository?: string | null; cwd?: string; summary: SessionSummary }[]>();
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

/// Read-only PR/issue references, tool sources, settled reply URLs and the images the person
/// pasted into their prompts, in transcript encounter order; each appears once.
function sources(rows: readonly AcpmuxRow[], pullRequests: readonly SummaryPullRequest[]): SummarySource[] {
  const seen = new Map<string, { source: SummarySource; order: number; sequence: number }>();
  let sequence = 0;
  const add = (source: SummarySource, order: number) => {
    const key = sourceKey(source);
    const prior = seen.get(key);
    if (prior && order < prior.order) prior.order = order;
    if (!prior || (source.kind === "pullRequest" && prior.source.kind !== "pullRequest"))
      seen.set(key, { source, order: prior?.order ?? order, sequence: prior?.sequence ?? sequence++ });
  };
  // Match canonical GitHub links after removing query and fragment suffixes. Keep a separate
  // identity set so an issue-form link for a PR the chat changed cannot resurrect it as a Source.
  const knownPullRequests = new Map(pullRequests.map((pr) => [`${pr.repo.toLowerCase()}#${pr.number}`, pr]));
  const changedIdentities = new Set(
    pullRequests
      .filter((pr) => (pr.changed || pr.opened) && pr.kind !== "issue")
      .map((pr) => `${pr.repo.toLowerCase()}#${pr.number}`),
  );
  const addUrls = (text: string, order: number) => {
    for (const match of text.matchAll(/https?:\/\/[^\s"'<>)]+/g)) {
      const url = match[0]!.replace(/[.,;:!?]+$/, "");
      const normalizedUrl = url.split(/[?#]/, 1)[0]!;
      const reference = GITHUB_REFERENCE_URL.exec(normalizedUrl);
      const label = url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "");
      if (reference) {
        const [, owner, repo, path, number] = reference;
        const canonical = `https://github.com/${owner}/${repo}/${path}/${number}`;
        const identity = `${owner}/${repo}`.toLowerCase() + `#${number}`;
        const known = knownPullRequests.get(identity);
        if (known?.changed || known?.opened || changedIdentities.has(identity)) continue;
        const pr = path === "pull" || known?.kind === "pullRequest";
        add(
          {
            url: pr ? (known?.url ?? canonical) : canonical,
            label: pr || known?.kind === "issue" ? (known?.title ?? `${owner}/${repo} #${number}`) : label,
            kind: pr ? "pullRequest" : "issue",
          },
          order,
        );
      } else add({ url, label, kind: "url" }, order);
    }
  };
  for (const [rowIndex, row] of rows.entries()) {
    if (row.kind === "user") {
      // The person's own images only: another agent's or the Chief's prompt is not what they pasted.
      if (!row.untyped && !row.from)
        for (const image of row.images ?? [])
          add({ label: image.name ?? "", kind: "image", image: { id: image.id, src: image.src } }, rowIndex);
      continue;
    }
    if (row.kind === "assistant") {
      if (!row.streaming) addUrls(row.text ?? "", rowIndex);
      continue;
    }
    if (row.kind !== "activity") continue;
    for (const [toolIndex, tool] of (row.items ?? []).entries()) {
      if (!tool.tool) continue;
      const item = tool.tool;
      if (item.status !== "completed" || (item.exitCode ?? 0) !== 0) continue;
      const call = mcpCall(item);
      if (call && !mcpIsObservational(call)) continue;
      const inputFields = input(item);
      const inputCommandValue = inputFields.command;
      const inputCommandArray = Array.isArray(inputCommandValue);
      const inputCommand =
        field(inputCommandValue) ??
        (Array.isArray(inputCommandValue)
          ? inputCommandValue
              .map(String)
              .map((part) => (/\s/.test(part) ? JSON.stringify(part) : part))
              .join(" ")
          : undefined);
      const command = item.command
        ? pullRequestSourceCommand(item.command)
        : inputCommandArray
          ? ""
          : pullRequestSourceCommand(inputCommand ?? "");
      const title = item.command || inputCommand ? command : item.title;
      // When raw input carries a shell command, scanning the JSON would reintroduce URLs from
      // --body/--body-file payloads that the command sanitizer intentionally removed.
      const inputText = inputCommand ? "" : (item.inputSummary ?? "");
      const text = `${title} ${command} ${inputText} ${item.output ?? ""}`;
      const order = rowIndex + toolIndex / 1000;
      addUrls(text, order);
      if (item.kind === "fetch" && !/https?:\/\//.test(text)) add({ label: item.title }, order);
      if (item.kind === "read") for (const path of editedPaths(item)) add({ label: path, kind: "file" }, order);
      if (call) add({ label: mcpPlainName(call), kind: "mcp" }, order);
    }
  }
  // Add shorthand-only references after transcript URLs have been encountered, so a URL earlier
  // in the same reply keeps its position while PR evidence still promotes an issue-form link.
  for (const pr of pullRequests)
    if (!pr.changed && !pr.opened) {
      const ambiguous = pr.mentioned && !pr.kind;
      add(
        {
          // GitHub redirects /issues/N to the PR when N is a PR; a bare number proves neither kind.
          url: ambiguous ? `https://github.com/${pr.repo}/issues/${pr.number}` : pr.url,
          label: pr.title ?? (ambiguous ? `${pr.repo}#${pr.number}` : `${pr.repo} #${pr.number}`),
          kind: ambiguous ? "url" : (pr.kind ?? "pullRequest"),
        },
        pr.firstTouched ?? pr.touched ?? Number.MAX_SAFE_INTEGER,
      );
    }
  return [...seen.values()].sort((a, b) => a.order - b.order || a.sequence - b.sequence).map(({ source }) => source);
}

/// The pull requests the chat opened.
export const sessionPullRequests = (rows: readonly AcpmuxRow[]) =>
  transcriptPullRequests(rows).filter((pr) => pr.opened && pr.kind !== "issue");

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

/// The chat's background shells, the ended ones too (the Background tasks panel lists them).
export const transcriptBackgroundTasks = (rows: readonly AcpmuxRow[]) => backgroundTasks(rows, tools(rows));

/// The background shells and the count of scheduled wakeups in `rows`, from one pass: what Session
/// Info's Background tasks lists from a transcript (the palette's Show Background Tasks, App.tsx).
export function transcriptBackground(rows: readonly AcpmuxRow[]): {
  tasks: SummaryBackgroundTask[];
  scheduled: number;
} {
  const all = tools(rows);
  return { tasks: backgroundTasks(rows, all), scheduled: scheduled(all).length };
}

/// The chat's background shells still running (the running turn's line counts them, WorkingFor.tsx).
export const runningBackgroundTasks = (rows: readonly AcpmuxRow[]) =>
  transcriptBackgroundTasks(rows).filter((task) => task.state === "running");

/// What the chat made. With `repository` (the chat folder's `owner/name`, or null when it has
/// none), Session Info's Changes: its pull requests include the ones the agent only named in a
/// reply, a bare `#N` in that repository among them; without it, only the ones it opened or touched.
export function sessionSummary(rows: readonly AcpmuxRow[], repository?: string | null, cwd?: string): SessionSummary {
  const producerRevision = transcriptSummaryVersion(rows);
  const cached = producerRevision ? (summaryCache.get(producerRevision) ?? []) : [];
  const match = cached.find((entry) => entry.repository === repository && entry.cwd === cwd);
  if (match) return match.summary;
  const all = tools(rows);
  const inspector = repository !== undefined;
  // The summary card reads only the commands, and lists no mention.
  const folder = repository ?? undefined;
  const pullRequests = transcriptPullRequests(rows, { folder, replies: inspector });
  const result = {
    ...(cwd ? { cwd } : {}),
    scheduled: scheduled(all),
    pullRequests: (inspector ? pullRequests : pullRequests.filter((pr) => !pr.mentioned)).filter(
      (pr) => pr.kind !== "issue",
    ),
    outputs: cwd === undefined ? turnFiles(rows as AcpmuxRow[]) : filesInProject(turnFiles(rows as AcpmuxRow[]), cwd),
    subagents: subagents(rows, all),
    sources: sources(rows, pullRequests),
    backgroundTasks: backgroundTasks(rows, all),
  };
  if (producerRevision) {
    cached.push({ repository, cwd, summary: result });
    summaryCache.set(producerRevision, cached);
  }
  return result;
}

export const isEmptySummary = (summary: SessionSummary) =>
  Object.values(summary).every((value) => !Array.isArray(value) || value.length === 0);
