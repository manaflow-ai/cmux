// A pull request's View diff (Session Info's Changes and Sources rows): its Files tab's address,
// which the App opens as the pull request's diff in the diff viewer beside the chat, with no
// github.com page in between (WebPageTab.openGitHubDiff). Leo, 2026-11-05: "you want to see the
// diff? Boom, here's a diff. ... We can know which one to give you."
const PULL_REQUEST = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/([1-9]\d{0,9})(?:\/[a-z]{1,20})?\/?$/;

/// `url`'s Files tab (`https://github.com/<owner>/<repo>/pull/<n>/files`), undefined for anything
/// but a plain pull request link (an issue, a query, an anchor).
export function pullRequestDiffUrl(url: string | undefined): string | undefined {
  const match = url ? PULL_REQUEST.exec(url) : null;
  if (!match) return undefined;
  const [, owner, repo, number] = match;
  if (/^\.+$/.test(owner!) || /^\.+$/.test(repo!)) return undefined;
  return `https://github.com/${owner}/${repo}/pull/${number}/files`;
}
