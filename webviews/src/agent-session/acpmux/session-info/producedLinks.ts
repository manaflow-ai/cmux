// Session Info's Outputs: the pull requests, issues and commits the chat itself produced (Leo,
// 2026-11-07: "at least do what [the reference] has here with outputs. i think that'd be real good. esp
// since we have so many linked things here"). Read from what its tool calls did, never from what it
// only read: a pull request it viewed, waited on or commented on stays in Sources.
//
// Produced, from a call that succeeded:
// - a pull request it opened: `gh pr create` or `glaeda-gh post pr` (the URL the call printed), the
//   GitHub tools' `pr_create` (an MCP call, or `lane-gh call pr_create`), its printed `html_url`;
// - a pull request it merged: `gh pr merge N`, `gh-merge-green N`, the GitHub tools' `land`
//   (`{number}` on the call's repository);
// - an issue it filed: `gh issue create`, the GitHub tools' `issue_create` (the printed URL);
// - a commit it published: `git push`'s `old..new  src -> branch` line (the new head, on the
//   `To` repository), the GitHub tools' `push` (its `sha`).
// - a reply that says so, as the last resort: "opened", "filed", "merged" or "landed" directly before
//   a GitHub link, `owner/repo#N` or, in the folder's repository, `PR #N` / `#N`.
//
// Cost: each row's findings are kept per row object (a row is replaced, never changed, when it grows;
// direct.ts bumps its version), so an update reads only its new and changed rows, and a streaming
// reply is not read until it settles.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { mcpCall } from "../conversation/mcpCalls";
import { pullRequestSourceCommand } from "../summary/transcriptPullRequests";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type ProducedKind = "pullRequest" | "issue" | "commit";
/// One thing the chat produced: its GitHub page and what its row says ("PR #923", "#7395", a short sha).
export type ProducedLink = {
  readonly key: string;
  readonly kind: ProducedKind;
  /// `owner/name`.
  readonly repo: string;
  readonly url: string;
  /// The number of a pull request or issue.
  readonly number?: number;
  /// A commit's full sha as the call printed it.
  readonly sha?: string;
  /// The chat merged it (a pull request).
  readonly merged?: true;
};

type Finding =
  | { kind: "pullRequest" | "issue" | "either"; repo: string; number: number; merged?: true }
  | { kind: "pullRequestIn" | "eitherIn"; number: number; merged?: true }
  | { kind: "commit"; repo: string; sha: string };

const REPO = String.raw`([\w-][\w.-]*\/[\w.-]+?)`;
const PR_URL = new RegExp(String.raw`https:\/\/github\.com\/${REPO}\/pull\/(\d+)`, "g");
const ISSUE_URL = new RegExp(String.raw`https:\/\/github\.com\/${REPO}\/issues\/(\d+)`, "g");
const GITHUB_TOOL = /github/i;
/// `lane-gh call TOOL OWNER/REPO 'JSON'` (a lane VM's broker), its JSON quoted as the shell has it.
const LANE_CALL =
  /\blane-gh\s+call\s+(pr_create|issue_create|land|push)\s+([\w-][\w.-]*\/[\w.-]+)(?:\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)"))?/g;
const PR_CREATE = /\bgh\s+pr\s+create\b|\bglaeda-gh\s+post\s+pr(?=\s|$)/;
const ISSUE_CREATE = /\bgh\s+issue\s+create\b/;
/// `gh pr merge TARGET` or `gh-merge-green TARGET`, up to the end of the call.
const MERGE = /\b(?:gh\s+pr\s+merge|gh-merge-green)(?=\s|$)([^\n;&|]*)/g;
const REPO_FLAG = /(?:^|\s)(?:-R|--repo)[= ]([\w.-]+\/[\w.-]+)(?=\s|$)/;
/// `gh pr merge` flags that take no value; any other flag's next word is its value.
const SWITCHES = new Set(
  "--squash -s --merge -m --rebase -r --auto --admin --delete-branch -d --disable-auto".split(" "),
);
/// `git push`'s ref line: `   1a2b3c4..5d6e7f8  HEAD -> lane/x` (or `+ a...b` for a forced one).
const PUSHED = /^\s*[+ ]?\s*[0-9a-f]{7,40}\.\.\.?([0-9a-f]{7,40})\s+\S+\s+->\s+\S+/gm;
/// `To github.com:owner/repo.git` or `To https://github.com/owner/repo(.git)`.
const PUSHED_TO = /^To\s+(?:https:\/\/|ssh:\/\/git@|git@)?github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\/?\s*$/m;
/// A reply's own claim: a verb, then what it produced.
const SAID =
  /\b(opened|filed|merged|landed)\s+(?:(?:the\s+)?PR\s+|issue\s+)?\[?(https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:pull|issues)\/\d+|[\w-][\w.-]*\/[\w.-]+#\d+|(?:PR\s*)?#\d+)/gi;

const succeeded = (tool: Tool) => tool.status === "completed" && (tool.exitCode ?? 0) === 0;
const parse = (text: string | undefined): unknown => {
  try {
    return JSON.parse(text ?? "");
  } catch {
    return undefined;
  }
};
const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
const positive = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isInteger(value) && value > 0
    ? value
    : typeof value === "string" && /^[1-9]\d*$/.test(value)
      ? Number(value)
      : undefined;
const repoOf = (value: unknown): string | undefined =>
  typeof value === "string" && /^[\w-][\w.-]*\/[\w.-]+$/.test(value) ? value : undefined;
const shaOf = (value: unknown): string | undefined =>
  typeof value === "string" && /^[0-9a-f]{7,40}$/i.test(value) ? value.toLowerCase() : undefined;

/// A broker or MCP answer that says it failed (`{"ok": false}`, an `error`).
function refused(output: string | undefined): boolean {
  const answer = record(parse(output));
  return answer.ok === false || (typeof answer.error === "string" && answer.error !== "");
}

/// The page a create call printed: its `html_url`, else the first link of `pattern`'s kind.
function printed(output: string | undefined, pattern: RegExp, kind: "pullRequest" | "issue"): Finding[] {
  const answer = record(parse(output));
  const data = record(answer.data ?? answer);
  for (const value of [data.html_url, data.url]) {
    if (typeof value !== "string") continue;
    const match = new RegExp(`^${pattern.source}`).exec(value);
    if (match) return [{ kind, repo: match[1]!, number: Number(match[2]) }];
  }
  const match = new RegExp(pattern.source).exec(output ?? "");
  return match ? [{ kind, repo: match[1]!, number: Number(match[2]) }] : [];
}

/// What one GitHub tool call (an MCP call or the broker's `lane-gh call`) produced.
function githubTool(name: string, repo: string | undefined, args: unknown, output: string | undefined): Finding[] {
  if (refused(output)) return [];
  const input = record(args);
  const where = repo ?? repoOf(input.repo);
  if (name === "pr_create") return printed(output, PR_URL, "pullRequest");
  if (name === "issue_create") return printed(output, ISSUE_URL, "issue");
  if (name === "land") {
    const number = positive(input.number);
    return where && number ? [{ kind: "pullRequest", repo: where, number, merged: true }] : [];
  }
  if (name === "push") {
    const data = record(record(parse(output)).data);
    const sha = shaOf(data.sha) ?? shaOf(input.sha);
    return where && sha ? [{ kind: "commit", repo: where, sha }] : [];
  }
  return [];
}

/// The pull request a merge names: its first argument, after the flags and their values.
function mergeTarget(rest: string): Finding | undefined {
  const repoFlag = REPO_FLAG.exec(rest)?.[1];
  const words = rest.trim().split(/\s+/);
  for (let index = 0; index < words.length; index++) {
    const word = words[index]!;
    if (!word) continue;
    if (word.startsWith("-")) {
      if (!word.includes("=") && !SWITCHES.has(word)) index++;
      continue;
    }
    const url = new RegExp(`^${PR_URL.source}`).exec(word);
    if (url) return { kind: "pullRequest", repo: url[1]!, number: Number(url[2]), merged: true };
    const ref = /^([\w-][\w.-]*\/[\w.-]+)#(\d+)$/.exec(word);
    if (ref) return { kind: "pullRequest", repo: ref[1]!, number: Number(ref[2]), merged: true };
    const number = /^#?(\d+)$/.exec(word)?.[1];
    if (!number) return undefined;
    return repoFlag
      ? { kind: "pullRequest", repo: repoFlag, number: Number(number), merged: true }
      : { kind: "pullRequestIn", number: Number(number), merged: true };
  }
  return undefined;
}

/// What one shell call produced.
function shellFindings(command: string, output: string | undefined): Finding[] {
  const found: Finding[] = [];
  // The broker's calls, read from the command as written: their JSON is quoted data to the scan below.
  for (const match of command.matchAll(LANE_CALL))
    found.push(...githubTool(match[1]!, match[2]!, parse(match[3] ?? match[4]?.replace(/\\(.)/g, "$1")), output));
  // Bodies and titles are data, not the command: a PR body names other PRs.
  const plain = pullRequestSourceCommand(command);
  if (PR_CREATE.test(plain)) found.push(...printed(output, PR_URL, "pullRequest"));
  if (ISSUE_CREATE.test(plain)) found.push(...printed(output, ISSUE_URL, "issue"));
  for (const match of plain.matchAll(MERGE)) {
    const target = mergeTarget(match[1] ?? "");
    if (target) found.push(target);
  }
  if (/\bgit\s+(?:-C\s+\S+\s+)?push\b/.test(command) && output) {
    const repo = PUSHED_TO.exec(output)?.[1];
    if (repo) for (const match of output.matchAll(PUSHED)) found.push({ kind: "commit", repo, sha: match[1]! });
  }
  return found;
}

function toolFindings(tool: Tool): Finding[] {
  if (!succeeded(tool)) return [];
  if (tool.command) return shellFindings(tool.command, tool.output);
  const call = mcpCall(tool);
  if (call && GITHUB_TOOL.test(call.server)) return githubTool(call.tool, undefined, call.args, tool.output);
  return [];
}

/// A reply's own claims ("Opened https://github.com/o/r/pull/12", "merged #37845").
function replyFindings(text: string): Finding[] {
  if (!/\b(?:opened|filed|merged|landed)\b/i.test(text)) return [];
  const found: Finding[] = [];
  for (const match of text.replace(/```[\s\S]*?(?:```|$)/g, " ").matchAll(SAID)) {
    const verb = match[1]!.toLowerCase();
    const target = match[2]!;
    const merged = verb === "merged" || verb === "landed" ? { merged: true as const } : {};
    const url = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/(pull|issues)\/(\d+)$/.exec(target);
    if (url) {
      const pr = url[2] === "pull";
      found.push({ kind: pr ? "pullRequest" : "issue", repo: url[1]!, number: Number(url[3]), ...(pr ? merged : {}) });
      continue;
    }
    const ref = /^([\w-][\w.-]*\/[\w.-]+)#(\d+)$/.exec(target);
    const pr = verb !== "filed" && (verb !== "opened" || /^PR/i.test(target) || !!merged.merged);
    if (ref)
      found.push({
        kind: verb === "filed" ? "issue" : pr ? "pullRequest" : "either",
        repo: ref[1]!,
        number: Number(ref[2]),
        ...merged,
      });
    else {
      const number = Number(/(\d+)$/.exec(target)![1]);
      found.push({ kind: pr ? "pullRequestIn" : "eitherIn", number, ...merged });
    }
  }
  return found;
}

type Kept = { text?: string; items?: unknown; findings: Finding[] };
const perRow = new WeakMap<AcpmuxRow, Kept>();

function rowFindings(row: AcpmuxRow): Finding[] {
  if (row.kind === "assistant" ? row.streaming || !row.text : row.kind !== "activity") return [];
  const kept = perRow.get(row);
  if (kept && kept.text === row.text && kept.items === row.items) return kept.findings;
  const findings =
    row.kind === "activity"
      ? (row.items ?? []).flatMap((item) => (item.tool ? toolFindings(item.tool) : []))
      : replyFindings(row.text ?? "");
  perRow.set(row, { text: row.text, items: row.items, findings });
  return findings;
}

/// The short label a row shows: "PR #923" (`pullRequest`, the caller's translated form), "#7395", a
/// commit's first seven characters.
export function producedLabel(link: ProducedLink, pullRequest: (n: number) => string): string {
  if (link.kind === "commit") return link.sha!.slice(0, 7);
  return link.kind === "pullRequest" ? pullRequest(link.number!) : `#${link.number}`;
}

/// The pull requests, issues and commits the chat produced, in the order it first produced each, each
/// once (a pull request it opened and then merged is one row, merged). `repository` is the chat
/// folder's `owner/name`, for a bare number.
export function producedLinks(rows: readonly AcpmuxRow[], repository?: string | null): ProducedLink[] {
  const found = new Map<string, ProducedLink>();
  for (const row of rows)
    for (const finding of rowFindings(row)) {
      if (finding.kind === "commit") {
        const key = `commit:${finding.repo.toLowerCase()}@${finding.sha.slice(0, 7)}`;
        if (!found.has(key))
          found.set(key, {
            key,
            kind: "commit",
            repo: finding.repo,
            sha: finding.sha,
            url: `https://github.com/${finding.repo}/commit/${finding.sha}`,
          });
        continue;
      }
      const repo = "repo" in finding ? finding.repo : repository;
      if (!repo) continue;
      // Issues and pull requests share a number space: one row per number, a pull request once any
      // call proves it one.
      const key = `${repo.toLowerCase()}#${finding.number}`;
      const prior = found.get(key);
      const pr = finding.kind === "pullRequest" || finding.kind === "pullRequestIn" || prior?.kind === "pullRequest";
      const merged = !!(finding.merged || prior?.merged);
      // A Map keeps a key where it was first set: a later merge of an opened pull request moves nothing.
      found.set(key, {
        key,
        // An unknown kind ("opened #12") reads as an issue's `#N`: GitHub sends an /issues/N that is a
        // pull request on to it.
        kind: pr ? "pullRequest" : "issue",
        repo: prior?.repo ?? repo,
        number: finding.number,
        url: `https://github.com/${prior?.repo ?? repo}/${pr ? "pull" : "issues"}/${finding.number}`,
        ...(merged ? { merged: true as const } : {}),
      });
    }
  return [...found.values()];
}
