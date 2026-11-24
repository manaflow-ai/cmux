// Review from link: a pull request link's Review (the link hover card; the composer's URL chip
// calls the same `pr.review` direct action) opens a side chat with this prompt. The agent checks
// the pull request out into its own worktree, leaves each finding as a draft line comment in cmux's
// diff viewer and opens it; the person edits the drafts there and posts them as one GitHub review
// under their own login. The agent never posts: the prompt says so, and `cmux git review` has no
// post command.

/**
 * The pull request's canonical address, `https://github.com/OWNER/REPO/pull/N`, or undefined for
 * anything else (an issue, another host, a plain http link). A trailing path (`/files`, `/commits`),
 * query or fragment is dropped, so the prompt names the pull request itself.
 */
export function pullRequestUrl(text: string): string | undefined {
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" || url.hostname !== "github.com" || url.port !== "") return undefined;
  if (url.username !== "" || url.password !== "") return undefined;
  const match = /^\/([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)\/pull\/([1-9][0-9]*)(?:\/.*)?$/.exec(url.pathname);
  if (!match) return undefined;
  const [, owner, repo, number] = match;
  if (repo === "." || repo === "..") return undefined;
  return `https://github.com/${owner}/${repo}/pull/${number}`;
}

/** The side chat's first prompt for reviewing `url` (a `pullRequestUrl` result). It shows as sent. */
export function reviewPrompt(url: string): string {
  return [
    `Review the pull request ${url}. Don't post anything to GitHub: you leave drafts, and I post them.`,
    "",
    `1. Run \`cmux git review start ${url}\`. It checks the pull request out into its own worktree and prints the folder, its base commit and the diff command. Work only in that folder.`,
    "2. Read the whole change with the diff command it printed, and the code around it.",
    '3. For each real problem (a bug, a security or data-loss risk, a missing test for changed behavior), leave one draft on the line it is about: `cmux git review comment --path <folder> --file <path> --line <n> --message "<what is wrong and the fix>"`. Add `--start-line <m>` for a range and `--side old` for a removed line. Only lines in the diff take a draft. Skip style nits.',
    "4. Run `cmux browser open-diff-viewer --path <folder>` and reply in two or three sentences: how many drafts you left and the most important one.",
  ].join("\n");
}
