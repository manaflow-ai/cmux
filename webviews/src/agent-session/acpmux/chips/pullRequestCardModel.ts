// The host's own rule (AgentPaneReplyRequest.pullRequestURL): owner/repo, `pull`, the number, and
// at most one tab of it (`/files`); a query or a fragment is dropped before asking.
const PULL_REQUEST =
  /^https:\/\/github\.com\/([A-Za-z0-9_][\w.-]*\/[A-Za-z0-9_][\w.-]*)\/pull\/([1-9]\d{0,9})(?:\/[a-z]{1,20})?\/?(?:[?#].*)?$/i;

/// `owner/repo`, the number and the plain address of a GitHub pull request link, else undefined.
export function pullRequestRef(href: string): { repo: string; number: number; url: string } | undefined {
  const match = PULL_REQUEST.exec(href);
  if (!match) return undefined;
  return { repo: match[1]!, number: Number(match[2]), url: `https://github.com/${match[1]}/pull/${match[2]}` };
}
