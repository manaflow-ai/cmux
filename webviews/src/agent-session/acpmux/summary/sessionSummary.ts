// What a chat has produced so far, read from its transcript's tool calls: the pull requests it
// opened, the files it wrote, its subagents, the wakeups it scheduled and the web pages it
// read. The header's summary popover lists them (SummaryPopover).
import { turnFiles, type TurnFile } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type PullRequestState = "open" | "merged" | "closed";
export type SummaryPullRequest = { url: string; repo: string; number: number; title?: string; state: PullRequestState };
export type SummarySubagent = { id: string; title: string; state: "running" | "done" | "failed" };
export type SummaryWakeup = { id: string; text: string; cron?: string };
export type SummarySource = { url?: string; label: string };
export type SessionSummary = {
  scheduled: SummaryWakeup[];
  pullRequests: SummaryPullRequest[];
  outputs: TurnFile[];
  subagents: SummarySubagent[];
  sources: SummarySource[];
};

const PR_URL = /https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/g;
/// `--title "..."`, `--title '...'`, `--title=...` or `-t "..."` on a `gh pr create` line.
const TITLE = /(?:--title[= ]|-t )(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+))/;
const URL = /https?:\/\/[^\s"'<>)]+/;

const tools = (rows: readonly AcpmuxRow[]): Tool[] =>
  rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : []));

const succeeded = (tool: Tool) => tool.status === "completed" && (tool.exitCode ?? 0) === 0;

/// Pull requests a `gh pr create` call printed, then marked merged or closed by a later
/// successful `gh pr merge`, `gh-merge-green` or `gh pr close` naming the same number.
function pullRequests(all: readonly Tool[]): SummaryPullRequest[] {
  const found = new Map<string, SummaryPullRequest>();
  for (const tool of all) {
    const command = tool.command ?? "";
    if (/\bgh\s+pr\s+create\b/.test(command) && succeeded(tool)) {
      const title = TITLE.exec(command);
      for (const [url, repo, number] of (tool.output ?? "").matchAll(PR_URL))
        if (!found.has(url))
          found.set(url, {
            url,
            repo: repo!,
            number: Number(number),
            title: title ? (title[1] ?? title[2] ?? title[3])?.replace(/\\(.)/g, "$1") : undefined,
            state: "open",
          });
      continue;
    }
    const merged = /\bgh\s+pr\s+merge\s+(?:\S*\/pull\/)?#?(\d+)|\bgh-merge-green\s+\S*#(\d+)/.exec(command);
    const closed = /\bgh\s+pr\s+close\s+(?:\S*\/pull\/)?#?(\d+)/.exec(command);
    const match = merged ?? closed;
    if (!match || !succeeded(tool)) continue;
    const number = Number(match[1] ?? match[2]);
    for (const pr of found.values()) if (pr.number === number) pr.state = merged ? "merged" : "closed";
  }
  return [...found.values()];
}

/// Claude's Task tool arrives as a `think` tool call titled with the subagent's description.
function subagents(all: readonly Tool[]): SummarySubagent[] {
  return all
    .filter((tool) => tool.kind === "think" && tool.title.trim() !== "")
    .map((tool) => ({
      id: tool.id,
      title: tool.title,
      state: tool.status === "completed" ? "done" : tool.status === "failed" ? "failed" : "running",
    }));
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

export function sessionSummary(rows: readonly AcpmuxRow[]): SessionSummary {
  const all = tools(rows);
  return {
    scheduled: scheduled(all),
    pullRequests: pullRequests(all),
    outputs: turnFiles(rows as AcpmuxRow[]),
    subagents: subagents(all),
    sources: sources(all),
  };
}

export const isEmptySummary = (summary: SessionSummary) =>
  Object.values(summary).every((list: unknown[]) => list.length === 0);
