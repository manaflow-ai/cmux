// The host's own rule (AgentPaneReplyRequest.githubItemURL): owner/repo, `pull` or `issues`, the
// number, and for a pull request at most one tab of it (`/files`); a query or a fragment is dropped
// before asking.
const GITHUB_ITEM =
  /^https:\/\/github\.com\/([A-Za-z0-9_][\w.-]*\/[A-Za-z0-9_][\w.-]*)\/(pull|issues)\/([1-9]\d{0,9})(\/[a-z]{1,20})?\/?(?:[?#].*)?$/i;

export type GitHubItemRef = { repo: string; number: number; url: string; kind: "pull" | "issue" };

/// `owner/repo`, the number, the plain address and the kind of a GitHub pull request or issue link,
/// else undefined. Its card reads either (Leo 2026-11-08: an issue's card showed only its link).
export function githubItemRef(href: string): GitHubItemRef | undefined {
  const match = GITHUB_ITEM.exec(href);
  if (!match) return undefined;
  const pull = match[2]!.toLowerCase() === "pull";
  // An issue has no tabs: `/issues/7/files` is not an issue's address.
  if (!pull && match[4]) return undefined;
  const repo = match[1]!;
  const number = Number(match[3]);
  return pull
    ? { repo, number, url: `https://github.com/${repo}/pull/${number}`, kind: "pull" }
    : { repo, number, url: `https://github.com/${repo}/issues/${number}`, kind: "issue" };
}

/// `owner/repo`, the number and the plain address of a GitHub pull request link, else undefined.
export function pullRequestRef(href: string): { repo: string; number: number; url: string } | undefined {
  const ref = githubItemRef(href);
  return ref?.kind === "pull" ? { repo: ref.repo, number: ref.number, url: ref.url } : undefined;
}
