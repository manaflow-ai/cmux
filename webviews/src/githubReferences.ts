/** GitHub issue and pull request references written in prose. */
export type GithubReference = {
  start: number;
  end: number;
  text: string;
  href: string;
  /** A bare `#N`, which named no repository: its number (`href` is `repository`'s). */
  bare?: number;
};

/** A lone GitHub issue URL that can seed a new fix worktree. */
export type GithubIssueLink = {
  url: string;
  owner: string;
  repository: string;
  number: number;
};

/** Parses the exact GitHub issue URL form accepted by the New Tab fix action. */
export function githubIssueLink(text: string): GithubIssueLink | undefined {
  const value = text.trim();
  if (!value || /\s/.test(value)) return undefined;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return undefined;
  }
  if (parsed.protocol !== "https:" || !["github.com", "www.github.com"].includes(parsed.hostname.toLowerCase()))
    return undefined;
  const parts = parsed.pathname.split("/").filter(Boolean);
  if (parts.length !== 4 || parts[2] !== "issues" || !/^[1-9][0-9]{0,9}$/.test(parts[3]!)) {
    return undefined;
  }
  const [owner, repository] = parts;
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(owner!) || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repository!)) {
    return undefined;
  }
  parsed.pathname = `/` + parts.slice(0, 3).concat(parts[3]!).join("/");
  parsed.search = "";
  parsed.hash = "";
  return {
    url: parsed.toString(),
    owner: owner!,
    repository: repository!,
    number: Number(parts[3]),
  };
}

// Not after a word, a path or URL (`x.com/#12`) or an HTML entity (`&#123;`). GitHub numbers
// start at 1 and have at most ten digits (the pull request card's rule), so `#0`, `#012` and
// `#12345678901` are not references.
// A short name glued to the `#` (`hq#12`, `subrouter-internal#54`) is a reference only when the
// caller takes aliases and it is a known one (REPOSITORY_ALIASES); any other word glued to a `#`
// (`foo#12`, `F#7`) stays text.
const REFERENCE =
  /(?<![\w./&-])(?:(?<repository>[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*)(?<qualifiedNumber>#[1-9][0-9]{0,9})|(?<alias>[A-Za-z][A-Za-z0-9-]*)(?<aliasNumber>#[1-9][0-9]{0,9})|(?<bareNumber>#[1-9][0-9]{0,9}))(?![\w])/g;

/// The repositories cmux's own agents name by their short name (`subrouter-internal#54`, Leo
/// 2026-11-07: "should we auto-render this as a link?"). Nothing else in the app lists them, so
/// this does; a name two of them share would name neither, and is left out (shortNames).
export const KNOWN_REPOSITORIES: readonly string[] = [
  "manaflow-ai/cmux",
  "manaflow-ai/cmuxterm-hq",
  "manaflow-ai/cmux-platform",
  "manaflow-ai/cmux-design-references",
  "manaflow-ai/subrouter",
  "manaflow-ai/subrouter-internal",
  "teamleaderleo/leo-workspace",
];

/// Each repository's name, when no other repository in `repositories` has it.
export function shortNames(repositories: readonly string[]): Map<string, string> {
  const out = new Map<string, string>();
  const shared = new Set<string>();
  for (const repository of repositories) {
    const name = repository.slice(repository.indexOf("/") + 1).toLowerCase();
    if (out.has(name)) shared.add(name);
    else out.set(name, repository);
  }
  for (const name of shared) out.delete(name);
  return out;
}

/// Short repository names agents write in place of `owner/repo` (`hq#2713`, `lw#12`,
/// `subrouter-internal#54`), in agent replies only.
export const REPOSITORY_ALIASES: ReadonlyMap<string, string> = new Map([
  ...shortNames(KNOWN_REPOSITORIES),
  ["hq", "manaflow-ai/cmuxterm-hq"],
  ["lw", "teamleaderleo/leo-workspace"],
]);

/**
 * Finds explicit `owner/repo#123` and, when known, bare `#123` references. `kind` picks the
 * address: `issues` (the markdown editor) or `pull` (agent replies, whose chips open the pull
 * request card); GitHub redirects either to the other when the number is the other kind.
 * `aliases`: also `hq#123` and the other REPOSITORY_ALIASES (agent replies).
 */
export function githubReferences(
  text: string,
  repository?: string,
  kind: "issues" | "pull" = "issues",
  aliases = false,
): GithubReference[] {
  const out: GithubReference[] = [];
  for (const match of text.matchAll(REFERENCE)) {
    const alias = match.groups?.alias;
    const repo = alias
      ? aliases
        ? REPOSITORY_ALIASES.get(alias.toLowerCase())
        : undefined
      : (match.groups?.repository ?? repository);
    if (!repo) continue;
    const number = match.groups?.qualifiedNumber ?? match.groups?.aliasNumber ?? match.groups?.bareNumber;
    if (!number) continue;
    out.push({
      start: match.index!,
      end: match.index! + match[0].length,
      text: match[0],
      href: `https://github.com/${repo}/${kind}/${number.slice(1)}`,
      ...(match.groups?.bareNumber ? { bare: Number(number.slice(1)) } : {}),
    });
  }
  return out;
}

/** A commit written in prose: `owner/repo@<sha>`, or a bare SHA when the repository is known. */
export type CommitReference = GithubReference & { sha: string };

// 7 to 40 lowercase hex characters with at least one digit and one letter (git's short and full
// forms; `deadbeef`, `1234567` and `facade` stay words), not glued to a word, a path, a `#` color,
// a `0x` number or a `sha256:` digest (64 characters, past the 40 cap anyway).
const COMMIT =
  /(?<![\w./#&:@-])(?:(?<repository>[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*)@)?(?<sha>(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40})(?![\w-])/g;

/** Commits in `text`, linked to their GitHub page; a bare SHA needs `repository`, unless `bare`
 * keeps it with an empty `href` (an agent's message draws every SHA the same quiet way). */
export function commitReferences(text: string, repository?: string, bare = false): CommitReference[] {
  const out: CommitReference[] = [];
  for (const match of text.matchAll(COMMIT)) {
    const repo = match.groups?.repository ?? repository;
    const sha = match.groups!.sha!;
    if (!repo && !bare) continue;
    out.push({
      start: match.index!,
      end: match.index! + match[0].length,
      text: match[0],
      sha,
      href: repo ? `https://github.com/${repo}/commit/${sha}` : "",
    });
  }
  return out;
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
/** Whether `owner` (an address's first segment) can be an owner, not one of github.com's own pages. */
export const isGithubOwner = (owner: string) => !NOT_OWNERS.has(owner.toLowerCase());

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
