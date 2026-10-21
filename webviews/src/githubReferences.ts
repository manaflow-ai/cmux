/** GitHub issue and pull request references written in prose. */
export type GithubReference = {
  start: number;
  end: number;
  text: string;
  href: string;
};

// Not after a word, a path or URL (`x.com/#12`) or an HTML entity (`&#123;`). GitHub numbers
// start at 1 and have at most ten digits (the pull request card's rule), so `#0`, `#012` and
// `#12345678901` are not references.
const REFERENCE =
  /(?<![\w./&-])(?:(?<repository>[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*)(?<qualifiedNumber>#[1-9][0-9]{0,9})|(?<bareNumber>#[1-9][0-9]{0,9}))(?![\w])/g;

/**
 * Finds explicit `owner/repo#123` and, when known, bare `#123` references. `kind` picks the
 * address: `issues` (the markdown editor) or `pull` (agent replies, whose chips open the pull
 * request card); GitHub redirects either to the other when the number is the other kind.
 */
export function githubReferences(
  text: string,
  repository?: string,
  kind: "issues" | "pull" = "issues",
): GithubReference[] {
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
      href: `https://github.com/${repo}/${kind}/${number.slice(1)}`,
    });
  }
  return out;
}

// `hq#123`: a pull request or issue of the team's HQ repository, as agents write it to each other.
const HQ_REFERENCE = /(?<![\w./&-])hq#([1-9][0-9]{0,9})(?![\w])/gi;
const HQ_REPOSITORY = "manaflow-ai/cmuxterm-hq";
// A commit's name: 7 to 40 lowercase hex characters with a digit and a letter, so neither a number
// nor a word reads as one. Not in a path, a URL or its query, a color (`#a1b2c3d4`), a hex literal, an
// address or a UUID.
const COMMIT = /(?<![\w./@:#=&?%+~-])(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![\w/@-])/g;

/**
 * The references agents write to each other besides `#123`: `hq#123` (HQ's pull request, which
 * GitHub redirects to the issue) and, when the repository is known, a commit's name, whose `text`
 * is its first seven characters.
 */
export function agentReferences(text: string, repository?: string): GithubReference[] {
  const out: GithubReference[] = [];
  for (const match of text.matchAll(HQ_REFERENCE)) {
    out.push({
      start: match.index!,
      end: match.index! + match[0].length,
      text: match[0],
      href: `https://github.com/${HQ_REPOSITORY}/pull/${match[1]}`,
    });
  }
  if (repository) {
    for (const match of text.matchAll(COMMIT)) {
      out.push({
        start: match.index!,
        end: match.index! + match[0].length,
        text: match[0].slice(0, 7),
        href: `https://github.com/${repository}/commit/${match[0]}`,
      });
    }
  }
  return out.sort((a, b) => a.start - b.start);
}

// A fenced block (to its closing fence, or the end of an unfinished one) and a code span.
const CODE = /^[ \t]*(`{3,}|~{3,})[\s\S]*?(?:^[ \t]*\1|(?![\s\S]))|(`+)[^`]*?\2/gm;
// github.com's own pages, whose first segment is not an owner (`gh auth login` prints
// github.com/login/device).
const NOT_OWNERS = new Set([
  "about",
  "apps",
  "codespaces",
  "collections",
  "contact",
  "customer-stories",
  "enterprise",
  "enterprises",
  "explore",
  "features",
  "issues",
  "join",
  "login",
  "logout",
  "marketplace",
  "new",
  "notifications",
  "orgs",
  "organizations",
  "pricing",
  "pulls",
  "search",
  "security",
  "settings",
  "site",
  "sponsors",
  "topics",
  "trending",
  "users",
]);
const GITHUB_URL = /(?<![\w.-])(?:https?:\/\/)?(?:www\.)?github\.com\/([A-Za-z0-9][\w.-]*\/[A-Za-z0-9][\w.-]*)/g;

/** The repository `text` mentions last in prose (`owner/repo#N` or a github.com address). */
export function mentionedRepository(text: string): string | undefined {
  if (!text.includes("#") && !text.includes("github.com")) return undefined;
  const prose = text.replace(CODE, " ");
  let at = -1;
  let repository: string | undefined;
  for (const ref of githubReferences(prose)) {
    at = ref.start;
    repository = ref.text.slice(0, ref.text.indexOf("#"));
  }
  for (const match of prose.matchAll(GITHUB_URL)) {
    if (match.index! < at || NOT_OWNERS.has(match[1]!.split("/")[0]!.toLowerCase())) continue;
    at = match.index!;
    repository = match[1]!.replace(/\.+$/, "").replace(/\.git$/, "");
  }
  return repository;
}

/** The repository the latest of `texts` that mentions one mentions (mentionedRepository). */
export function latestMentionedRepository(texts: readonly (string | undefined)[]): string | undefined {
  for (let index = texts.length - 1; index >= 0; index--) {
    const repository = texts[index] ? mentionedRepository(texts[index]!) : undefined;
    if (repository) return repository;
  }
  return undefined;
}
