/** GitHub issue and pull request references written in prose. */
export type GithubReference = {
  start: number;
  end: number;
  text: string;
  href: string;
};

const REFERENCE =
  /(?<![\w./-])(?:(?<repository>[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*)(?<qualifiedNumber>#[0-9]+)|(?<bareNumber>#[0-9]+))(?![\w])/g;

/** Finds explicit `owner/repo#123` and, when known, bare `#123` references. */
export function githubReferences(text: string, repository?: string): GithubReference[] {
  const out: GithubReference[] = [];
  for (const match of text.matchAll(REFERENCE)) {
    const repo = match.groups?.repository ?? repository;
    if (!repo) continue;
    const number = match.groups?.qualifiedNumber ?? match.groups?.bareNumber;
    if (!number) continue;
    out.push({
      start: match.index!,
      end: match.index! + match[0].length,
      text: match[0],
      href: `https://github.com/${repo}/issues/${number.slice(1)}`,
    });
  }
  return out;
}
