// Every pull request a chat created, merged, steered or named, across repositories, read from its
// transcript (the Inspector's Changes, Claude Code desktop's). The sources, in transcript order:
//
// - a `gh pr create` or `glaeda-gh post pr` call: the pull request URL it printed, which the chat
//   opened, with the `--title` it gave;
// - any other successful shell call: the pull request URLs and `owner/repo#N` its command names
//   (quoted text and heredoc bodies left out: a comment's body names other pull requests), and a
//   `gh pr <verb> N` with its `-R owner/repo` or else the chat folder's repository;
// - the agent's replies: pull request URLs, `owner/repo#N`, `repo #N` or `repo#N` for a repository
//   the transcript or the folder names, and a bare `#N` in the chat folder's repository. These are
//   only mentions: an issue is written the same way, so Changes keeps one only once GitHub says it
//   is a pull request.
//
// A successful `gh pr merge`, `gh-merge-green` or `gh pr close` marks it merged or closed, and
// `gh pr reopen` opens it again. Each one keeps where the chat last touched or named it, so
// Changes lists the most recent first.
import type { AcpmuxActivity, AcpmuxRow } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type PullRequestState = "open" | "merged" | "closed";
export type SummaryPullRequest = {
  url: string;
  repo: string;
  number: number;
  title?: string;
  state: PullRequestState;
  /// When the chat closed it (epoch ms), if the call says.
  closedAt?: number;
  /// The chat opened it (`gh pr create`, `glaeda-gh post pr`); false for one it only touched or named.
  opened: boolean;
  /// Only named in the agent's replies, never in a command: it may be an issue.
  mentioned?: boolean;
  /// Where in the transcript the chat last touched or named it (rises with each row), for order.
  touched?: number;
};

const PR_URL = /https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/g;
/// `--title "..."`, `--title '...'`, `--title=...` or `-t "..."` on a create line.
const TITLE = /(?:--title[= ]|-t )(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+))/;
/// `gh pr merge|close` with a number, `#N` or a pull request URL, and `gh-merge-green owner/repo#N`.
const PR_ARGUMENT = String.raw`(?:https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/|#)?(\d+)`;
const MERGE = new RegExp(String.raw`\bgh\s+pr\s+merge\s+${PR_ARGUMENT}|\bgh-merge-green\s+([\w.-]+\/[\w.-]+)?#(\d+)`);
const CLOSE = new RegExp(String.raw`\bgh\s+pr\s+close\s+${PR_ARGUMENT}`);
const REOPEN = new RegExp(String.raw`\bgh\s+pr\s+reopen\s+${PR_ARGUMENT}`);
const CREATE = /\bgh\s+pr\s+create\b|\bglaeda-gh\s+post\s+pr\b/;
/// A `gh pr` verb that acts on or reads one existing pull request, and `gh-merge-green`.
const TOUCH =
  /\bgh\s+pr\s+(?:merge|close|edit|comment|review|ready|reopen|checkout|view|checks|diff|update-branch)\b[^\n;&|]*|\bgh-merge-green\b[^\n;&|]*/g;
/// `owner/repo#N`, not inside a path or URL.
const REPO_REF = /(?<![\w/.:-])([\w.-]+)\/([\w.-]+)#(\d+)\b/g;
const REPO_FLAG = /(?:^|\s)(?:-R|--repo)[= ]([\w.-]+\/[\w.-]+)\b/;
const BARE_NUMBER = /(?:^|\s)#?(\d+)(?=\s|$)/;
/// `repo #N` or `repo#N` in a reply.
const NAMED_REF = /(?<![\w/.#-])([\w.-]+) ?#(\d+)\b/g;
/// A bare `#N` in a reply.
const BARE_REF = /(?<![\w/.#&-])#(\d+)\b/g;
const QUOTED = /"(?:[^"\\]|\\.)*"|'[^']*'/g;
/// A heredoc's body (`<<EOF` … `EOF`, `<<'EOF'`, `<<-EOF`), which is data, not the command.
const HEREDOC = /<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?(?:\n\s*\2\b|$)/g;

const succeeded = (tool: Tool) => tool.status === "completed" && (tool.exitCode ?? 0) === 0;
const urlOf = (repo: string, number: number) => `https://github.com/${repo}/pull/${number}`;
/// A command without the text it carries as data.
const bare = (command: string) => command.replace(HEREDOC, "\n").replace(QUOTED, " ");

type Named = { repo: string; number: number };

/// The pull request a touching `gh pr` call names by URL, repository and number, or number in the
/// chat folder's repository.
function touched(call: string, folder: string | undefined): Named | undefined {
  const url = new RegExp(PR_URL.source).exec(call);
  if (url) return { repo: url[1]!, number: Number(url[2]) };
  const ref = new RegExp(REPO_REF.source).exec(call);
  if (ref) return { repo: `${ref[1]}/${ref[2]}`, number: Number(ref[3]) };
  const repo = REPO_FLAG.exec(call)?.[1] ?? folder;
  const number = BARE_NUMBER.exec(call.replace(REPO_FLAG, " "))?.[1];
  return repo && number ? { repo, number: Number(number) } : undefined;
}

/// Every `owner/repo` the transcript names (with the folder's), by repository name, for `repo #N`.
function knownRepositories(rows: readonly AcpmuxRow[], folder: string | undefined): Map<string, string> {
  const known = new Map<string, string>();
  const add = (repo: string) => {
    const name = repo.split("/")[1]?.toLowerCase();
    if (name && !known.has(name)) known.set(name, repo);
  };
  if (folder) add(folder);
  for (const row of rows) {
    const texts =
      row.kind === "activity"
        ? // Commands, and a create's output (its URL); other output can be megabytes of logs.
          (row.items ?? []).flatMap(({ tool }) =>
            tool ? [tool.command ?? "", CREATE.test(tool.command ?? "") ? (tool.output ?? "") : ""] : [],
          )
        : row.kind === "assistant"
          ? [row.text ?? ""]
          : [];
    for (const text of texts) {
      for (const match of text.matchAll(PR_URL)) add(match[1]!);
      for (const match of text.matchAll(REPO_REF)) add(`${match[1]}/${match[2]}`);
    }
  }
  return known;
}

/// The pull requests a reply names, in the order it names them.
function mentions(text: string, folder: string | undefined, known: ReadonlyMap<string, string>): Named[] {
  const found: Named[] = [];
  // Links and `owner/repo#N` first, then blanked so their numbers are not read again as `#N`.
  let rest = text.replace(PR_URL, (_, repo: string, number: string) => {
    found.push({ repo, number: Number(number) });
    return " ";
  });
  rest = rest.replace(REPO_REF, (_, owner: string, name: string, number: string) => {
    found.push({ repo: `${owner}/${name}`, number: Number(number) });
    return " ";
  });
  rest = rest.replace(NAMED_REF, (whole: string, name: string, number: string) => {
    const repo = known.get(name.toLowerCase());
    if (!repo) return whole;
    found.push({ repo, number: Number(number) });
    return " ";
  });
  if (folder) for (const match of rest.matchAll(BARE_REF)) found.push({ repo: folder, number: Number(match[1]) });
  return found.filter((named) => named.number > 0);
}

/// The chat's pull requests in the order it first touched or named them. `folder` is the chat
/// folder's GitHub repository (`owner/name`), for a bare number.
export function transcriptPullRequests(rows: readonly AcpmuxRow[], folder?: string): SummaryPullRequest[] {
  const found = new Map<string, SummaryPullRequest>();
  const known = knownRepositories(rows, folder);
  let at = 0;
  const note = ({ repo, number }: Named, how: "opened" | "touched" | "mentioned", title?: string) => {
    const url = urlOf(repo, number);
    const pr = found.get(url);
    if (!pr) {
      found.set(url, {
        url,
        repo,
        number,
        ...(title ? { title } : {}),
        state: "open",
        opened: how === "opened",
        ...(how === "mentioned" ? { mentioned: true } : {}),
        touched: at,
      });
      return;
    }
    pr.touched = at;
    if (how !== "mentioned") delete pr.mentioned;
    if (how === "opened") pr.opened = true;
    if (title && !pr.title) pr.title = title;
  };
  for (const row of rows) {
    at += 1;
    if (row.kind === "assistant") {
      for (const named of mentions(row.text ?? "", folder, known)) note(named, "mentioned");
      continue;
    }
    if (row.kind !== "activity") continue;
    for (const tool of (row.items ?? []).flatMap((item) => item.tool ?? [])) {
      if (!succeeded(tool)) continue;
      const command = tool.command ?? "";
      if (CREATE.test(command)) {
        const title = TITLE.exec(command);
        const text = title ? (title[1] ?? title[2] ?? title[3])?.replace(/\\(.)/g, "$1") : undefined;
        for (const match of (tool.output ?? "").matchAll(PR_URL))
          note({ repo: match[1]!, number: Number(match[2]) }, "opened", text);
        continue;
      }
      const plain = bare(command);
      for (const [call] of plain.matchAll(TOUCH)) {
        const named = touched(call, folder);
        if (named) note(named, "touched");
      }
      for (const match of plain.matchAll(PR_URL)) note({ repo: match[1]!, number: Number(match[2]) }, "touched");
      for (const match of plain.matchAll(REPO_REF))
        note({ repo: `${match[1]}/${match[2]}`, number: Number(match[3]) }, "touched");
      settle(found, plain, tool);
    }
  }
  return [...found.values()];
}

/// A merge, close or reopen the call ran, on the pull requests it names.
function settle(found: Map<string, SummaryPullRequest>, command: string, tool: Tool) {
  const merged = MERGE.exec(command);
  const reopened = REOPEN.exec(command);
  const match = merged ?? CLOSE.exec(command) ?? reopened;
  if (!match) return;
  // A URL, `owner/repo#N` or `-R owner/repo` names its repository; a bare number could be any.
  const repo = match[1] ?? match[3] ?? REPO_FLAG.exec(command)?.[1];
  const number = Number(match[2] ?? match[4]);
  for (const pr of found.values())
    if (pr.number === number && (!repo || repo === pr.repo)) {
      pr.state = merged ? "merged" : match === reopened ? "open" : "closed";
      const at = tool.endedAt ?? tool.startedAt;
      if (pr.state === "closed" && at !== undefined) pr.closedAt = at;
      else if (pr.state === "open") delete pr.closedAt;
    }
}
