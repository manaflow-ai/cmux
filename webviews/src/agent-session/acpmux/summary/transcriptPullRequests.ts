// Every pull request a chat created, changed or named, across repositories, read from its transcript.
// Changes consumes the created/mutated rows; read-only references feed Session Info's Sources. The
// findings are collected in transcript order:
//
// - a `gh pr create` or `glaeda-gh post pr` call: the pull request URL it printed, which the chat
//   opened, with the `--title` it gave;
// - any other successful shell call: the pull request URLs it names; the pull request a `gh pr`
//   verb, `gh-merge-green` or `glaeda-gh … pr` names (its first argument, by URL, `owner/repo#N`, or
//   a number in its `-R owner/repo`, else the chat folder's repository). Quoted text and heredoc
//   bodies are data, not the command: a comment's body names other pull requests;
// - mentions, which may be issues (`owner/repo#N` in any other command; with `replies`, the agent's
//   replies: URLs, `owner/repo#N`, `repo #N` for a repository the transcript or folder names, and a
//   bare `#N` in the folder's repository). Changes lists a mention once the App reads it as a pull
//   request.
//
// A successful merge (`gh pr merge`, `gh-merge-green`), `gh pr close` or `gh pr reopen` sets the
// state of the pull request it names. Each one keeps where the chat last touched or named it, so
// Changes lists the most recent first. A row's findings are kept per row object, so a transcript
// that grows re-reads only its new and changed rows.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { shellCommands, isPullRequestCommand } from "./shellCommands";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type PullRequestState = "open" | "merged" | "closed";
export type SummaryPullRequest = {
  url: string;
  repo: string;
  number: number;
  /// An issue reference is kept in the same transcript stream for Sources, but never Changes.
  kind?: "pullRequest" | "issue";
  title?: string;
  state: PullRequestState;
  /// When the chat closed it (epoch ms), if the call says.
  closedAt?: number;
  /// The chat opened it (`gh pr create`, `glaeda-gh post pr`); false for one it only touched or named.
  opened: boolean;
  /// Opened or mutated pull requests belong in Changes.
  changed?: boolean;
  /// Only named, never acted on as a pull request: it may be an issue.
  mentioned?: boolean;
  /// The first transcript row that named it, for Sources' encounter order.
  firstTouched?: number;
  /// Where in the transcript the chat last touched or named it (rises with each row), for order.
  touched?: number;
};

const PR_URL = /https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/g;
const ISSUE_URL = /https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/issues\/(\d+)/g;
/// `--title "..."`, `--title '...'`, `--title=...` or `-t "..."` on a create line.
const TITLE = /(?:--title[= ]|-t )(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+))/;
const CREATE = /\bgh\s+pr\s+create\b|\bglaeda-gh\s+post\s+pr(?=\s|$)/;
const ISSUE_CALL = /\bgh\s+issue\s+([a-z][\w-]*)(?=\s|$)([^\n;&|]*)/g;
/// Writes sent through glaeda's broker are mutations even though they do not use `gh pr`.
const BROKER_CALL =
  /\bglaeda-gh\s+(?:[a-z][\w-]*\s+)*(pr-(?:comment|edit|close|reopen|merge|review|approve|request-changes|update-branch)|issue-(?:comment|edit|close|reopen|create|lock|unlock|delete|pin|unpin|transfer))(?=\s|$)([^\n;&|]*)/g;
/// One call that acts on a single pull request: a `gh pr` verb, `gh-merge-green`, or `glaeda-gh`
/// with a `pr` argument (`wait pr`, `status pr`, `checks pr`), up to the end of the call.
const CALL =
  /\b(?:gh\s+pr\s+([a-z][\w-]*)|gh-merge-green|glaeda-gh\s+(?:[a-z][\w-]*\s+)*?pr(?:\s+([a-z][\w-]*))?)(?=\s|$)([^\n;&|]*)/g;
/// `owner/repo#N`, not inside a path or URL.
const REPO_REF = /(?<![\w/.:#-])([\w-][\w.-]*)\/([\w.-]+)#(\d+)\b/g;
const OWNER_REPO_REF = /^([\w-][\w.-]*)\/([\w.-]+)#(\d+)$/;
const REPO_FLAG = /(?:^|\s)(?:-R|--repo)[= ]([\w.-]+\/[\w.-]+)(?=\s|$)/;
/// `repo #N` or `repo#N` in a reply.
const NAMED_REF = /(?<![\w/.#-])([\w][\w.-]*)( ?)#(\d+)\b/g;
/// A bare `#N` in a reply.
const BARE_REF = /(?<![\w/.#&-])#(\d+)\b/g;
const QUOTED = /"(?:[^"\\]|\\.)*"|'[^']*'/g;
const SHELL_WORD = String.raw`(?:\\[\s\S]|"(?:[^"\\]|\\.)*"|'[^']*'|[^\s\\;&|()"'])+`;
const PAYLOAD_VALUE = new RegExp(String.raw`(?<!\S)(?:--body(?:-file)?|--title|-b|-t)(?:=|\s+)(${SHELL_WORD})`, "g");
/// A heredoc's body (`<<EOF` … `EOF`, `<<'EOF'`, `<<-EOF`), up to its terminator line; the rest
/// of the opening line stays (it is often the command that reads it). Never `<<<` or a shift.
const HEREDOC = /(?<!<)<<-?[ \t]*(['"]?)([A-Za-z_]\w*)\1([^\n]*)\n[\s\S]*?\n[ \t]*\2(?=[ \t]*(?:\n|$))/g;
const FENCE = /```[\s\S]*?(?:```|$)/g;
/// `gh pr` and `gh-merge-green` flags that take no value; any other flag's next word is its value.
const SWITCHES = new Set([
  "--squash",
  "-s",
  "--merge",
  "-m",
  "--rebase",
  "-r",
  "--auto",
  "--admin",
  "--delete-branch",
  "-d",
  "--disable-auto",
  "--watch",
  "--web",
  "-w",
  "--draft",
  "--approve",
  "-a",
  "--comment",
  "-c",
  "--request-changes",
  "--fail-fast",
  "--required",
  "--undo",
  "--comments",
  "--name-only",
  "--patch",
  "--rebase",
  "--force",
  "--detach",
  "--yes",
  "--json-only",
]);
const SETTLES: Record<string, PullRequestState> = { merge: "merged", close: "closed", reopen: "open" };
const ISSUE_MUTATING = new Set("create edit comment close reopen lock unlock delete pin unpin transfer".split(" "));
const MUTATING = new Set("merge close edit comment review ready reopen lock unlock update-branch".split(" "));

const succeeded = (tool: Tool) => tool.status === "completed" && (tool.exitCode ?? 0) === 0;
const urlOf = (repo: string, number: number) => `https://github.com/${repo}/pull/${number}`;
const issueUrlOf = (repo: string, number: number) => `https://github.com/${repo}/issues/${number}`;
/// Keep quoted targets available, and retain a harmless word for other quoted data so
/// a nonempty loop iterable or command argument never disappears during sanitization.
const quotedTarget = (value: string) =>
  new RegExp(`^${PR_URL.source}(?:[/?#]\\S*)?$`).test(value) ||
  new RegExp(`^${ISSUE_URL.source}(?:[/?#]\\S*)?$`).test(value) ||
  OWNER_REPO_REF.test(value) ||
  /^#?\d+$/.test(value) ||
  /^[\w.-]+\/[\w.-]+$/.test(value);
const callText = (command: string) =>
  command
    .replace(PAYLOAD_VALUE, " ")
    .replace(HEREDOC, "$3\n")
    .replace(QUOTED, (quoted) => {
      const value = quoted.slice(1, -1);
      return quotedTarget(value) ? value : "__quoted_data__";
    })
    .replace(/(^|[ \t;&|])#.*$/gm, "$1");

/// Both consumers use the same executed branches and exclude quoted payloads.
export const pullRequestSourceCommand = (command: string): string => shellCommands(callText(command)).join("\n");

/// Only explicit JSON title fields or a `.title` query are title evidence.
function outputTitle(tool: Tool): string | undefined {
  const output = tool.output?.trim();
  if (!output) return undefined;
  try {
    const value: unknown = JSON.parse(output);
    if (value && typeof value === "object" && typeof (value as { title?: unknown }).title === "string") {
      return (value as { title: string }).title.trim() || undefined;
    }
  } catch {
    // `gh pr view --jq .title` emits a plain line rather than JSON.
  }
  if (/(?:--jq|-q)(?:=|\s+)["']?\.title["']?(?=\s|$)/.test(tool.command ?? "") && !output.includes("\n")) return output;
  return undefined;
}

/// `name`: a repository by its name (`glaeda #12`); one the transcript never names is the word
/// before a bare `#N` ("Merged #12") when `orFolder`, else nothing.
type Ref = { kind: "full"; repo: string } | { kind: "name"; name: string; orFolder: boolean } | { kind: "folder" };
/// What one row says about pull requests, before the folder and the transcript's repositories
/// resolve its `#N` and `repo #N`.
type Finding =
  | { how: "opened"; repo: string; number: number; title?: string; kind?: "pullRequest" | "issue" }
  | {
      how: "touched" | "mentioned";
      ref: Ref;
      number: number;
      changed?: boolean;
      title?: string;
      kind?: "pullRequest" | "issue";
    }
  | { how: "settle"; ref: Ref; number: number; state: PullRequestState; at?: number };

/// The pull request a call names: its first argument, after the flags and their values.
function callTarget(rest: string): { ref: Ref; number: number } | undefined {
  const repoFlag = REPO_FLAG.exec(rest)?.[1];
  const words = rest.trim().split(/\s+/);
  for (let index = 0; index < words.length; index++) {
    const word = words[index]!;
    if (!word) continue;
    if (word.startsWith("-")) {
      if (!word.includes("=") && !SWITCHES.has(word)) index++;
      continue;
    }
    const url = new RegExp(`^${PR_URL.source}(?:[/?#]\\S*)?$`).exec(word);
    if (url) return { ref: { kind: "full", repo: url[1]! }, number: Number(url[2]) };
    const issue = new RegExp(`^${ISSUE_URL.source}(?:[/?#]\\S*)?$`).exec(word);
    if (issue) return { ref: { kind: "full", repo: issue[1]! }, number: Number(issue[2]) };
    const ref = OWNER_REPO_REF.exec(word);
    if (ref) return { ref: { kind: "full", repo: `${ref[1]}/${ref[2]}` }, number: Number(ref[3]) };
    const number = /^#?(\d+)$/.exec(word)?.[1];
    if (!number) return undefined;
    return { ref: repoFlag ? { kind: "full", repo: repoFlag } : { kind: "folder" }, number: Number(number) };
  }
  return undefined;
}

function toolFindings(tool: Tool): Finding[] {
  if (!succeeded(tool)) return [];
  const command = tool.command ?? "";
  // Strip body/title payloads before URL and shorthand scans; those are data, not activity.
  const scanPlain = pullRequestSourceCommand(command);
  const calls = scanPlain
    .split("\n")
    .filter((part) => isPullRequestCommand(part) && !/(?:^|\s)(?:--help|-h)(?=\s|$)/.test(part));
  const found: Finding[] = [];
  const createCount = calls.filter((call) => CREATE.test(call)).length;
  if (createCount > 0) {
    const title = createCount === 1 ? TITLE.exec(command) : null;
    const text = title ? (title[1] ?? title[2] ?? title[3])?.replace(/\\(.)/g, "$1") : undefined;
    // Shell output has no per-command boundary. Exclude explicit targets of other
    // calls, then require one distinct remaining URL per create. Ambiguous output
    // stays unclassified instead of attributing every viewed PR to a create.
    const otherTargets = calls.flatMap((call) =>
      CREATE.test(call) ? [] : [...call.matchAll(CALL)].flatMap((match) => callTarget(match[3] ?? "") ?? []),
    );
    const candidates = new Map<string, RegExpMatchArray>();
    for (const match of (tool.output ?? "").matchAll(PR_URL)) {
      if (
        otherTargets.some(
          (target) =>
            target.number === Number(match[2]) &&
            (target.ref.kind !== "full" || target.ref.repo.toLowerCase() === match[1]!.toLowerCase()),
        )
      )
        continue;
      candidates.set(`${match[1]!.toLowerCase()}#${match[2]}`, match);
    }
    if (candidates.size === createCount)
      for (const match of candidates.values())
        found.push({
          how: "opened",
          repo: match[1]!,
          number: Number(match[2]),
          ...(text ? { title: text } : {}),
        });
    // Continue scanning the same successful shell for later commands separated by &&/;.
  }
  // Preserve execution order across gh and broker lifecycle commands.
  for (const call of calls) {
    for (const match of call.matchAll(ISSUE_CALL)) {
      const action = match[1]!;
      const target = callTarget(match[2] ?? "");
      const targets = target
        ? [target]
        : action === "create"
          ? [...(tool.output ?? "").matchAll(ISSUE_URL)].map((match) => ({
              ref: { kind: "full" as const, repo: match[1]! },
              number: Number(match[2]),
            }))
          : [];
      for (const target of targets)
        found.push({
          how: ISSUE_MUTATING.has(action) ? "touched" : "mentioned",
          ...target,
          ...(ISSUE_MUTATING.has(action) ? { changed: true } : {}),
          kind: "issue",
          title: outputTitle(tool),
        });
    }
    for (const match of call.matchAll(BROKER_CALL)) {
      const target = callTarget(match[2] ?? "");
      if (!target) continue;
      const issue = match[1]!.startsWith("issue-");
      found.push({
        how: "touched",
        ref: target.ref,
        number: target.number,
        changed: true,
        kind: issue ? "issue" : "pullRequest",
        ...(outputTitle(tool) ? { title: outputTitle(tool) } : {}),
      });
      const state = !issue && SETTLES[match[1]!.slice(3)];
      if (state) found.push({ how: "settle", ...target, state, at: tool.endedAt ?? tool.startedAt });
    }
    for (const match of call.matchAll(CALL)) {
      const action = match[1] ?? match[2];
      const target = callTarget(match[3] ?? "");
      if (!target) continue;
      const titleMatch = action === "edit" ? TITLE.exec(command) : undefined;
      const title = (action === "edit" && calls.length === 1 ? titleMatch : undefined)
        ? (titleMatch![1] ?? titleMatch![2] ?? titleMatch![3])?.replace(/\\(.)/g, "$1")
        : action === "view" && calls.length === 1
          ? outputTitle(tool)
          : undefined;
      found.push({
        how: "touched",
        ref: target.ref,
        number: target.number,
        ...(match[0].startsWith("gh-merge-green") || (action && MUTATING.has(action)) ? { changed: true } : {}),
        ...(title ? { title } : {}),
      });
      const state = match[0].startsWith("gh-merge-green") ? "merged" : SETTLES[action ?? ""];
      if (state)
        found.push({
          how: "settle",
          ref: target.ref,
          number: target.number,
          state,
          at: tool.endedAt ?? tool.startedAt,
        });
    }
  }
  for (const match of scanPlain.matchAll(PR_URL))
    found.push({ how: "touched", ref: { kind: "full", repo: match[1]! }, number: Number(match[2]) });
  for (const match of scanPlain.matchAll(REPO_REF))
    found.push({
      how: "mentioned",
      ref: { kind: "full", repo: `${match[1]}/${match[2]}` },
      number: Number(match[3]),
    });
  for (const match of scanPlain.matchAll(ISSUE_URL))
    found.push({ how: "mentioned", ref: { kind: "full", repo: match[1]! }, number: Number(match[2]), kind: "issue" });
  return found;
}

/// The pull requests a reply names: links, then `owner/repo#N`, then `repo #N`, then a bare `#N`.
function replyFindings(text: string): Finding[] {
  if (!text.includes("#") && !text.includes("/pull/") && !text.includes("/issues/")) return [];
  const found: Finding[] = [];
  const mention = (ref: Ref, number: string, kind?: "pullRequest" | "issue") =>
    found.push({ how: "mentioned", ref, number: Number(number), kind });
  // Links and `owner/repo#N` first, then blanked so their numbers are not read again as `#N`.
  let rest = text.replace(PR_URL, (_, repo: string, number: string) => {
    mention({ kind: "full", repo }, number, "pullRequest");
    return " ";
  });
  rest = rest.replace(ISSUE_URL, (_, repo: string, number: string) => {
    mention({ kind: "full", repo }, number, "issue");
    return " ";
  });
  rest = rest.replace(REPO_REF, (_, owner: string, name: string, number: string) => {
    mention({ kind: "full", repo: `${owner}/${name}` }, number);
    return " ";
  });
  // A code block's `#N` is code (a color, a fragment), not a pull request.
  rest = rest.replace(FENCE, " ");
  rest = rest.replace(NAMED_REF, (_, name: string, space: string, number: string) => {
    const word = name.toLowerCase();
    // `PR #5`, `PR#5`: the folder's.
    if (word === "pr" || word === "pull") mention({ kind: "folder" }, number, "pullRequest");
    else mention({ kind: "name", name: word, orFolder: space === " " }, number);
    return " ";
  });
  for (const match of rest.matchAll(BARE_REF)) mention({ kind: "folder" }, match[1]!);
  return found;
}

/// Each row's findings, for the row object they were read from. A row's findings do not depend on
/// the options (a reply is only read when `replies` asks), so readers with and without `replies`
/// share them.
const cache = new WeakMap<AcpmuxRow, Finding[]>();

function rowFindings(row: AcpmuxRow, replies: boolean): Finding[] {
  if (row.kind !== "activity" && !(replies && row.kind === "assistant")) return [];
  if (row.kind === "assistant" && row.streaming) return [];
  const kept = cache.get(row);
  if (kept) return kept;
  const findings =
    row.kind === "activity"
      ? (row.items ?? []).flatMap((item) => (item.tool ? toolFindings(item.tool) : []))
      : replyFindings(row.text ?? "");
  cache.set(row, findings);
  return findings;
}

// Live snapshots carry a producer-maintained PR activity revision. Reading it is O(1):
// deriving a fingerprint by walking the transcript in render would cost O(rows) per token.
const activityVersions = new WeakMap<readonly AcpmuxRow[], symbol>();
const commandVersions = new WeakMap<readonly AcpmuxRow[], symbol>();
const summaryVersions = new WeakMap<readonly AcpmuxRow[], object>();
export const markPullRequestActivityVersion = (rows: readonly AcpmuxRow[], version: symbol): void => {
  activityVersions.set(rows, version);
};
export const markPullRequestCommandVersion = (rows: readonly AcpmuxRow[], version: symbol): void => {
  commandVersions.set(rows, version);
};
export const markTranscriptSummaryVersion = (rows: readonly AcpmuxRow[], version: object): void => {
  summaryVersions.set(rows, version);
};
export const transcriptSummaryVersion = (rows: readonly AcpmuxRow[]): object | undefined => summaryVersions.get(rows);
const fingerprints = new WeakMap<AcpmuxRow, string>();

// The producer asks only about the row it changed. A reply chunk with the same PR references
// leaves the revision alone; a new mention updates it without scanning historical replies.
export function pullRequestRowKey(row: AcpmuxRow | undefined, replies = true): string {
  if (!row) return "";
  // Streaming references may change the dock key, but settling identical text must change it too.
  const findings =
    row.kind === "assistant" ? (replies ? replyFindings(row.text ?? "") : []) : rowFindings(row, replies);
  if (findings.length === 0) return "";
  let fingerprint = fingerprints.get(row);
  if (fingerprint === undefined) {
    fingerprint = JSON.stringify([row.streaming === true, findings]);
    fingerprints.set(row, fingerprint);
  }
  return fingerprint;
}

export function transcriptPullRequestKey(rows: readonly AcpmuxRow[], replies = false): string | symbol {
  // Both consumers use producer revisions to avoid scanning historical rows on every token.
  const version = (replies ? activityVersions : commandVersions).get(rows);
  if (version !== undefined) return version;
  // Static/gallery rows have no producer. Their fallback keeps the same parsing semantics.
  return rows
    .flatMap((row, index) => {
      const fingerprint = pullRequestRowKey(row, replies);
      return fingerprint ? [`${index}:${fingerprint}`] : [];
    })
    .join("\n");
}

export type TranscriptPullRequestOptions = {
  /// The chat folder's GitHub repository (`owner/name`), for a bare number.
  folder?: string;
  /// Read the agent's replies for mentions too (Session Info); the composer's pull request bars
  /// and the summary card need only the commands.
  replies?: boolean;
};

/// The chat's pull requests in the order it first touched or named them.
export function transcriptPullRequests(
  rows: readonly AcpmuxRow[],
  { folder, replies = false }: TranscriptPullRequestOptions = {},
): SummaryPullRequest[] {
  const perRow = rows.map((row) => rowFindings(row, replies));
  // Every repository the transcript names, by its name, for `repo #N`.
  const known = new Map<string, string>();
  const learn = (repo: string) => {
    const name = repo.split("/")[1]?.toLowerCase();
    if (name && !known.has(name)) known.set(name, repo);
  };
  if (folder) learn(folder);
  for (const findings of perRow)
    for (const finding of findings)
      if (finding.how === "opened") learn(finding.repo);
      else if (finding.ref?.kind === "full") learn(finding.ref.repo);
  const resolve = (ref: Ref): string | undefined =>
    ref.kind === "full"
      ? ref.repo
      : ref.kind === "name"
        ? (known.get(ref.name) ?? (ref.orFolder ? folder : undefined))
        : folder;

  // Issues and pull requests share a number space. Keep one record per repository/number so an
  // `/issues/N` mention and a later (or earlier) PR reference cannot leave duplicate Sources.
  const found = new Map<string, SummaryPullRequest>();
  const note = (
    repo: string,
    number: number,
    how: "opened" | "touched" | "mentioned",
    at: number,
    title?: string,
    changed = false,
    kind?: "pullRequest" | "issue",
    encounter = at,
  ) => {
    if (number <= 0) return;
    const prUrl = urlOf(repo, number),
      issueUrl = issueUrlOf(repo, number),
      identity = `${repo.toLowerCase()}#${number}`;
    // GitHub issues and PRs share a number space; /issues/N may redirect to a proven PR. Once a
    // record has been proven as a PR, later issue evidence (including comment fragments) reuses it.
    const prior = found.get(identity);
    if ((!kind && how !== "mentioned") || prior?.kind === "pullRequest") kind = "pullRequest";
    if (!kind && prior?.kind) kind = prior.kind;
    const url = kind === "issue" ? issueUrl : prUrl;
    const pr = prior;
    if (pr) {
      pr.url = url;
    }
    if (!pr) {
      found.set(identity, {
        url,
        repo,
        number,
        ...(kind ? { kind } : how !== "mentioned" ? { kind: "pullRequest" as const } : {}),
        ...(title ? { title } : {}),
        state: "open",
        opened: how === "opened",
        ...(changed || how === "opened" ? { changed: true } : {}),
        ...(how === "mentioned" ? { mentioned: true } : {}),
        firstTouched: encounter,
        touched: at,
      });
      return;
    }
    pr.touched = at;
    if (kind) pr.kind = kind;
    else if (how !== "mentioned") pr.kind = "pullRequest";
    if (how !== "mentioned") delete pr.mentioned;
    if (how === "opened") pr.opened = true;
    if (changed || how === "opened") pr.changed = true;
    if (title) pr.title = title;
  };
  perRow.forEach((findings, index) => {
    const at = index + 1;
    findings.forEach((finding, findingIndex) => {
      const encounter = index + findingIndex / 1000;
      if (finding.how === "opened") {
        note(finding.repo, finding.number, "opened", at, finding.title, true, finding.kind, encounter);
        return;
      }
      const repo = resolve(finding.ref);
      if (finding.how !== "settle") {
        if (repo) note(repo, finding.number, finding.how, at, finding.title, finding.changed, finding.kind, encounter);
        return;
      }
      // Without a repository (no `-R`, no folder), a merge names every one with its number.
      for (const pr of found.values())
        if (pr.number === finding.number && (!repo || repo.toLowerCase() === pr.repo.toLowerCase())) {
          pr.state = finding.state;
          if (pr.state === "closed" && finding.at !== undefined) pr.closedAt = finding.at;
          else if (pr.state === "open") delete pr.closedAt;
        }
    });
  });
  return [...found.values()];
}
