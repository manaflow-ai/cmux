// Every id a reply's prose links, one registry entry per kind (Leo 2026-11-10, of "build
// 4270949510401," as plain text: "should these be linked too?"). Each kind used to be its own
// matcher spliced into proseText.tsx by hand, so a kind nobody spliced in (a nightly build, an
// Actions run) stayed text; a new kind is now one entry in ID_KINDS, and the rules every kind
// shares (inside a URL or a path it is part of that, the first of two overlapping ids wins) are
// here once.
import {
  commitReferences,
  githubReferences,
  runReferences,
  type CommitReference,
  type GithubReference,
  type RunReference,
} from "../../../githubReferences";
import { textLinks } from "../chips/paths";

/** One id in prose: a pull request or issue, a commit, or a nightly build or Actions run. */
export type ProseId =
  | ({ kind: "reference" } & GithubReference)
  | ({ kind: "commit"; quiet: boolean } & CommitReference)
  | ({ kind: "run" } & RunReference);

export type ProseIdOptions = {
  /** The repository a bare id means (the chat's), if any. */
  repository?: string;
  /** An agent's message draws every SHA the same quiet way (proseText.tsx `cv-sha`). */
  quietCommits?: boolean;
  /** Whether a bare `#N` is kept (BareReferenceChip links it from the transcript's evidence). */
  bare?: boolean;
};

type IdKind = {
  /** The ids of this kind in `text`; `before` holds the kinds listed above it, found first. */
  find: (text: string, options: ProseIdOptions, before: readonly ProseId[]) => ProseId[];
  /** Whether an id may stand inside a URL or a path, which then keeps it (`?v=3a7bd3e2`). */
  inLinks: (id: ProseId) => boolean;
};

// Bare `#N` with no repository still goes to BareReferenceChip, which links it only when the
// transcript names its repository.
const NO_REPOSITORY = "-/-";

const ID_KINDS: readonly IdKind[] = [
  {
    // `owner/repo#N`, `hq#N`, `#N`: a pull request address, so the chip opens the pull request card
    // (an issue redirects there). Only `owner/repo#N` is whole in a URL's text; `?repo=cmux#3` is not.
    find: (text, { repository }) =>
      githubReferences(text, repository ?? NO_REPOSITORY, "pull", true).map((ref) => ({ ...ref, kind: "reference" })),
    inLinks: (id) => id.kind === "reference" && !id.bare && id.text.includes("/"),
  },
  {
    // `abc1234`, `owner/repo@abc1234`: the commit's GitHub page.
    find: (text, { repository, quietCommits }, before) =>
      (quietCommits
        ? quietCommitReferences(
            text,
            before.filter((id) => id.kind === "reference"),
            repository,
          )
        : commitReferences(text, repository)
      ).map((commit) => ({ ...commit, kind: "commit", quiet: Boolean(quietCommits) })),
    inLinks: () => false,
  },
  {
    // `build 4270949510401`, `nightly 4270949510401`, `run 42709495104`: the run's page. A run is
    // the repository's the nearest reference before it names (`cmux#1 failed in run N`), else the
    // chat's.
    find: (text, { repository }, before) =>
      runReferences(text, (at) => repositoryBefore(at, before) ?? repository).map((run) => ({ ...run, kind: "run" })),
    inLinks: () => false,
  },
];

/** The ids in `text` to link, in reading order, none overlapping another and none inside a URL or
 * a path (unless its kind is whole there). */
export function proseIds(text: string, options: ProseIdOptions = {}): ProseId[] {
  const found: ProseId[] = [];
  for (const kind of ID_KINDS) found.push(...kind.find(text, options, found));
  const loose = found.filter((id) => !ID_KINDS.some((kind) => kind.inLinks(id)));
  const spans = loose.length ? textLinks(text) : [];
  const outside = (id: ProseId) => !spans.some((span) => id.start < span.end && span.start < id.end);
  return found
    .filter((id) => {
      if (ID_KINDS.some((kind) => kind.inLinks(id))) return true;
      if (id.kind === "reference" && id.bare && options.bare === false) return false;
      return outside(id);
    })
    .sort((a, b) => a.start - b.start)
    .filter((id, index, all) => index === 0 || id.start >= all[index - 1]!.end);
}

/** The repository the last reference ending before `at` names. */
function repositoryBefore(at: number, before: readonly ProseId[]): string | undefined {
  const reference = before.filter((id) => id.kind === "reference" && id.end <= at).at(-1);
  const repo = reference ? /^https:\/\/github\.com\/([^/]+\/[^/]+)\//.exec(reference.href)?.[1] : undefined;
  return repo === NO_REPOSITORY ? undefined : repo;
}

/// Every commit SHA in `text` (an agent's message): each links to its commit in the repository it
/// names (`owner/repo@sha`), else that of the nearest reference before it in the same text
/// (`hq#2563 (db0677c6)` is a cmuxterm-hq commit), else `repository`; with none it is text.
function quietCommitReferences(text: string, issues: readonly ProseId[], repository?: string): CommitReference[] {
  return commitReferences(text, undefined, true).map((commit) => {
    if (commit.href) return commit;
    const before = issues.filter((issue) => issue.end <= commit.start).at(-1);
    const repo = before ? /^https:\/\/github\.com\/([^/]+\/[^/]+)\//.exec(before.href)?.[1] : repository;
    const text = commit.sha.length > 10 ? commit.sha.slice(0, 8) : commit.text;
    return repo ? { ...commit, text, href: `https://github.com/${repo}/commit/${commit.sha}` } : { ...commit, text };
  });
}
