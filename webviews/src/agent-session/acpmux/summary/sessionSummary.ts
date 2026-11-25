// What a chat has produced so far, read from its transcript's tool calls: the pull requests it
// opened, the files it wrote, its subagents, the wakeups it scheduled and the web pages it
// read. The summary card lists them (SummaryCard.tsx, SummaryBody.tsx).
import { toolFiles, type TurnFile } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { isSubagentGroup } from "../subagents/subagentRows";
import { mcpCall, mcpIsObservational, mcpPlainName } from "../conversation/mcpCalls";
import { editedPaths } from "../toolPaths";
import { PrefixFilter, PrefixFlatCache, type PrefixFlat } from "../conversation/prefixFlatMap";
import {
  pullRequestSourceCommand,
  transcriptPullRequests,
  transcriptSummaryVersion,
  type SummaryPullRequest,
} from "./transcriptPullRequests";

export type { PullRequestState, SummaryPullRequest } from "./transcriptPullRequests";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type SummarySubagent = { id: string; title: string; state: "running" | "done" | "failed" };
export type SummaryWakeup = {
  id: string;
  text: string;
  /// Claude's ScheduleWakeup (`wakeup`) or CronCreate (`cron`).
  kind: "wakeup" | "cron";
  cron?: string;
  /// When the call was made (epoch ms, the session's clock), when known.
  startedAt?: number;
  /// A wakeup's time: its call's start plus its `delaySeconds`.
  dueAt?: number;
  /// A cron job's `recurring` (Claude's default is true); false runs it once.
  recurring?: boolean;
  /// A later CronDelete named this job: when it ran.
  cancelledAt?: number;
  /// The call failed, so nothing was scheduled.
  failed?: true;
};
export type SummarySourceKind = "url" | "pullRequest" | "issue" | "file" | "mcp" | "image";
/// `image`: a pasted image's id in its prompt, its bytes when the prompt carried them, and the app
/// it was copied from when acpmux kept that (its Sources row reads "<source> screenshot 2").
export type SummarySource = {
  url?: string;
  label: string;
  kind?: SummarySourceKind;
  image?: { id: string; src?: string; source?: string };
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

/// The chat's tool calls in transcript order, read again only past the rows an update kept
/// (conversation/prefixFlatMap.ts): Session Info asks for them on every summary it makes.
const tools = (rows: readonly AcpmuxRow[]): readonly Tool[] => toolReads.read(rows).items;
const toolReads = new PrefixFlatCache<AcpmuxRow, Tool>((row) =>
  row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : NONE,
);
const NONE: readonly never[] = [];
const subagentGroups = new PrefixFilter<AcpmuxRow>(isSubagentGroup);

/// The session's own subagents, from its subagent groups (subagents/subagentFold.ts); records
/// from before acpmux reported subagents carry Claude's Task tool as a `think` tool call titled
/// with the subagent's description instead.
function subagents(rows: readonly AcpmuxRow[], all: readonly Tool[]): SummarySubagent[] {
  const grouped = subagentGroups
    .read(rows)
    .items.flatMap((row) => row.subagents ?? [])
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

/// A tool call's input: `inputSummary` carries its `rawInput` as JSON. Parsed once per call: each
/// summary reads the input of every background shell again, and a chat of 28,408 of them parsed
/// each one three times per summary. A call is never edited in place (direct.ts `mergeToolItem` and
/// `markBackgroundCall` make a new one); the text is checked all the same. Callers only read it.
function input(tool: Tool): Record<string, unknown> {
  const kept = inputs.get(tool);
  if (kept && kept.text === tool.inputSummary) return kept.fields;
  let fields: Record<string, unknown> = {};
  try {
    const value: unknown = JSON.parse(tool.inputSummary ?? "");
    if (value && typeof value === "object") fields = value as Record<string, unknown>;
  } catch {
    // Not JSON: no fields.
  }
  inputs.set(tool, { text: tool.inputSummary, fields });
  return fields;
}
const inputs = new WeakMap<Tool, { text: string | undefined; fields: Record<string, unknown> }>();

const field = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);

/// Claude Code clamps a wakeup's delay to one minute ... one hour.
const WAKEUP_DELAY_SECONDS = { min: 60, max: 3600 };

const SCHEDULING = /^(ScheduleWakeup|CronCreate)\b/;

const CRON_DELETE = /^CronDelete\b/;

/// Wakeups and cron jobs the agent scheduled for itself (Claude's ScheduleWakeup and CronCreate),
/// named by their reason or prompt, with a cron job's schedule, when each was made and, for a
/// wakeup, when it is due; a cron job a later CronDelete named carries when it was removed. A
/// failed call is kept, marked, so it reads as failed rather than ahead (session-info/scheduled.ts).
/// From the calls already picked out: the scheduling calls and the CronDelete calls, in transcript order.
function scheduledFrom(scheduling: readonly Tool[], cronDeletes: readonly Tool[]): SummaryWakeup[] {
  // CronDelete names the job by the id its CronCreate's result printed.
  const deletes = cronDeletes.flatMap((tool) => {
    if (tool.status === "failed") return [];
    const id = field(input(tool).id);
    return id ? [{ id, at: tool.startedAt }] : [];
  });
  return scheduling.map((tool): SummaryWakeup => {
    const fields = input(tool);
    const kind = tool.title.startsWith("ScheduleWakeup") ? "wakeup" : "cron";
    const delay = typeof fields.delaySeconds === "number" ? fields.delaySeconds : undefined;
    const startedAt = tool.startedAt;
    const dueAt =
      kind === "wakeup" && startedAt !== undefined && delay !== undefined && Number.isFinite(delay)
        ? startedAt + Math.min(WAKEUP_DELAY_SECONDS.max, Math.max(WAKEUP_DELAY_SECONDS.min, delay)) * 1000
        : undefined;
    const output = tool.output ?? "";
    const deleted =
      kind === "cron" && output
        ? deletes.find((entry) => new RegExp(`(^|[^\\w-])${escapeRegExp(entry.id)}($|[^\\w-])`).test(output))
        : undefined;
    return {
      id: tool.id,
      text: field(fields.reason) ?? field(fields.prompt) ?? tool.title,
      kind,
      ...(field(fields.cron) ? { cron: field(fields.cron) } : {}),
      ...(startedAt !== undefined ? { startedAt } : {}),
      ...(dueAt !== undefined ? { dueAt } : {}),
      ...(typeof fields.recurring === "boolean" ? { recurring: fields.recurring } : {}),
      ...(deleted ? { cancelledAt: deleted.at ?? startedAt ?? 0 } : {}),
      ...(tool.status === "failed" ? { failed: true as const } : {}),
    };
  });
}

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

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

/// What one row, or one call in it, gives Sources before the chat's pull requests are known: a
/// source as it lists, or a link, with its parts when it is a GitHub pull request or issue (what
/// it lists as depends on what the chat did to that pull request, `sources`).
type SourceFind =
  | { source: SummarySource }
  | { url: string; label: string; github: { owner: string; repo: string; path: string; number: string } };

/// A row's finds and their place in it: a call's index / 1000 in its activity row, else 0.
type SourcePart = { at: number; finds: readonly SourceFind[] };

/// The links in `text`, in order.
/// Appends to `finds` rather than returning a list to spread: one tool output can hold more links than
/// a call takes arguments (`push(...list)` throws RangeError past the engine's argument limit).
function linkFinds(text: string, finds: SourceFind[] = []): SourceFind[] {
  for (const match of text.matchAll(/https?:\/\/[^\s"'<>)]+/g)) {
    const url = match[0]!.replace(/[.,;:!?]+$/, "");
    const normalizedUrl = url.split(/[?#]/, 1)[0]!;
    const reference = GITHUB_REFERENCE_URL.exec(normalizedUrl);
    const label = url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "");
    if (reference) {
      const [, owner, repo, path, number] = reference;
      finds.push({ url, label, github: { owner: owner!, repo: repo!, path: path!, number: number! } });
    } else finds.push({ source: { url, label, kind: "url" } });
  }
  return finds;
}

/// What a finished call gives Sources: the links in its title, command, input and output, a fetch
/// without one by its title, the files it read and its MCP tool. Read once per call: Session Info
/// made the summary again on every call's start and end, and read every finished call's whole
/// output for links each time (Leo, a chat of 28,408 background shells: "dam this is slow as shit on
/// the sesion info"). A call is never edited in place (direct.ts `mergeToolItem` makes a new one).
function toolSourceFinds(item: Tool): readonly SourceFind[] {
  if (item.status !== "completed" || (item.exitCode ?? 0) !== 0) return NONE;
  const kept = toolFinds.get(item);
  if (kept) return kept;
  const finds: SourceFind[] = [];
  const call = mcpCall(item);
  if (!call || mcpIsObservational(call)) {
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
    linkFinds(text, finds);
    if (item.kind === "fetch" && !/https?:\/\//.test(text)) finds.push({ source: { label: item.title } });
    if (item.kind === "read")
      for (const path of editedPaths(item)) finds.push({ source: { label: path, kind: "file" } });
    if (call) finds.push({ source: { label: mcpPlainName(call), kind: "mcp" } });
  }
  toolFinds.set(item, finds);
  return finds;
}
const toolFinds = new WeakMap<Tool, readonly SourceFind[]>();

/// What one row gives Sources, its finished reply read once per row object (`replyParts`).
function sourceParts(row: AcpmuxRow): readonly SourcePart[] {
  if (row.kind === "user") {
    // The person's own sent images only: another agent's or the Chief's prompt is not what they
    // pasted, and a prompt that failed to send gave the agent nothing.
    if (row.untyped || row.from || row.failed || !row.images?.length) return NONE;
    const finds = row.images.map((image): SourceFind => ({
      source: {
        label: image.name ?? "",
        kind: "image",
        image: { id: image.id, src: image.src, ...(image.source ? { source: image.source.name } : {}) },
      },
    }));
    return [{ at: 0, finds }];
  }
  if (row.kind === "assistant") {
    if (row.streaming) return NONE;
    const kept = replyParts.get(row);
    if (kept && kept.text === row.text) return kept.parts;
    const finds = linkFinds(row.text ?? "");
    const parts = finds.length ? [{ at: 0, finds }] : NONE;
    replyParts.set(row, { text: row.text, parts });
    return parts;
  }
  if (row.kind !== "activity") return NONE;
  const parts: SourcePart[] = [];
  for (const [toolIndex, item] of (row.items ?? []).entries()) {
    const finds = item.tool ? toolSourceFinds(item.tool) : NONE;
    if (finds.length) parts.push({ at: toolIndex / 1000, finds });
  }
  return parts;
}
const replyParts = new WeakMap<AcpmuxRow, { text: string | undefined; parts: readonly SourcePart[] }>();

/// Each row's finds, read again only past the rows an update kept; a page of older rows read
/// again finds each row's and call's finds kept (`replyParts`, `toolFinds`).
const sourceReads = new PrefixFlatCache<AcpmuxRow, SourcePart>(sourceParts);

/// Read-only PR/issue references, tool sources, settled reply URLs and the images the person
/// pasted into their prompts, in transcript encounter order; each appears once. The rows' finds are
/// kept (`sourceReads`); what a GitHub link lists as is decided here, from the chat's pull requests.
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
  const addFind = (find: SourceFind, order: number) => {
    if ("source" in find) return add(find.source, order);
    const { owner, repo, path, number } = find.github;
    const canonical = `https://github.com/${owner}/${repo}/${path}/${number}`;
    const identity = `${owner}/${repo}`.toLowerCase() + `#${number}`;
    const known = knownPullRequests.get(identity);
    if (known?.changed || known?.opened || changedIdentities.has(identity)) return;
    const pr = path === "pull" || known?.kind === "pullRequest";
    add(
      {
        url: pr ? (known?.url ?? canonical) : canonical,
        label: pr || known?.kind === "issue" ? (known?.title ?? `${owner}/${repo} #${number}`) : find.label,
        kind: pr ? "pullRequest" : "issue",
      },
      order,
    );
  };
  const read = sourceReads.read(rows);
  for (const [index, part] of read.items.entries()) {
    const order = read.from[index]! + part.at;
    for (const find of part.finds) addFind(find, order);
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

/// Shell calls only: a subagent's Agent call can run in the background too.
const backgroundShell = (tool: Tool) =>
  tool.kind === "execute" && (input(tool).run_in_background === true || !!tool.background);

type BackgroundEnd = ReturnType<typeof backgroundEnds>[number];

/// `backgroundTasks` over the background shells and the ends already picked out, in transcript order.
function backgroundTasksFrom(shells: readonly Tool[], ends: readonly BackgroundEnd[]): SummaryBackgroundTask[] {
  const ended = new Map(ends.map((end) => [end.toolCallId, end.state] as const));
  const launched = shells.map((tool): SummaryBackgroundTask => ({
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
export const transcriptBackgroundTasks = (rows: readonly AcpmuxRow[]) => background(rows).tasks;

/// The background shells and the count of scheduled wakeups in `rows`, from one pass: what Session
/// Info's Background tasks lists from a transcript (the palette's Show Background Tasks, App.tsx).
export function transcriptBackground(rows: readonly AcpmuxRow[]): TranscriptBackground {
  const found = background(rows);
  const kept = backgroundResults.get(found);
  if (kept) return kept;
  // The failed calls scheduled nothing; the ended ones still list, under "N finished".
  const result = { tasks: found.tasks, scheduled: found.wakeups.filter((item) => !item.failed).length };
  backgroundResults.set(found, result);
  return result;
}

/// Shells the agent ran in the background (Claude's Bash `run_in_background`, or a call it moved
/// there, cx-ncc.84), running until their call or a background task row says how they ended, and
/// the wakeups it scheduled (`scheduledFrom`), from one pass. The pane and Session Info call this on
/// every snapshot: only the rows after the last kept one are read again
/// (conversation/prefixFlatMap.ts), and the same rows give the same answer back.
function background(rows: readonly AcpmuxRow[]): BackgroundFound {
  const read = backgroundReads.read(rows);
  const kept = backgroundFound.get(read);
  if (kept) return kept;
  const calls = (kind: "shell" | "scheduling" | "cronDelete") =>
    read.items.flatMap((part) => (part.kind === kind && "tool" in part ? [part.tool] : []));
  const ends = read.items.flatMap((part) => ("end" in part ? [part.end] : []));
  const found = {
    tasks: backgroundTasksFrom(calls("shell"), ends),
    wakeups: scheduledFrom(calls("scheduling"), calls("cronDelete")),
  };
  backgroundFound.set(read, found);
  return found;
}

type BackgroundFound = { tasks: SummaryBackgroundTask[]; wakeups: SummaryWakeup[] };

type TranscriptBackground = { tasks: SummaryBackgroundTask[]; scheduled: number };

/// What one row gives `transcriptBackground`, in its order: its background shells, its scheduling
/// and CronDelete calls, and how a background shell ended.
type BackgroundPart = { kind: "shell" | "scheduling" | "cronDelete"; tool: Tool } | { kind: "end"; end: BackgroundEnd };

const backgroundParts = (row: AcpmuxRow): BackgroundPart[] => {
  const parts: BackgroundPart[] = [];
  if (row.kind === "activity")
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (!tool) continue;
      if (backgroundShell(tool)) parts.push({ kind: "shell", tool });
      if (SCHEDULING.test(tool.title)) parts.push({ kind: "scheduling", tool });
      if (CRON_DELETE.test(tool.title)) parts.push({ kind: "cronDelete", tool });
    }
  for (const end of backgroundEnds(row)) parts.push({ kind: "end", end });
  return parts;
};

/// The last `transcriptBackground` passes (each pane reads it per snapshot) and their answers.
const backgroundReads = new PrefixFlatCache<AcpmuxRow, BackgroundPart>((row) => backgroundParts(row));
const backgroundFound = new WeakMap<PrefixFlat<AcpmuxRow, BackgroundPart>, BackgroundFound>();
const backgroundResults = new WeakMap<BackgroundFound, TranscriptBackground>();

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
  // Each part reads again only the rows an update changed; the merges below walk what they found.
  const all = tools(rows);
  const found = background(rows);
  const inspector = repository !== undefined;
  // The summary card reads only the commands, and lists no mention.
  const folder = repository ?? undefined;
  const pullRequests = transcriptPullRequests(rows, { folder, replies: inspector });
  const result = {
    ...(cwd ? { cwd } : {}),
    scheduled: found.wakeups,
    pullRequests: (inspector ? pullRequests : pullRequests.filter((pr) => !pr.mentioned)).filter(
      (pr) => pr.kind !== "issue",
    ),
    outputs: cwd === undefined ? toolFiles(all, { known: true }) : filesInProject(toolFiles(all, { known: true }), cwd),
    subagents: subagents(rows, all),
    sources: sources(rows, pullRequests),
    backgroundTasks: found.tasks,
  };
  if (producerRevision) {
    cached.push({ repository, cwd, summary: result });
    summaryCache.set(producerRevision, cached);
  }
  return result;
}

export const isEmptySummary = (summary: SessionSummary) =>
  Object.values(summary).every((value) => !Array.isArray(value) || value.length === 0);
