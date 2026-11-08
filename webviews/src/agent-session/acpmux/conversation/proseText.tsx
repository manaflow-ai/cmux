import { type ReactNode } from "react";
import { GitHubMark } from "./icons";
import { UrlChip } from "../chips/LinkChips";
import { linkedText } from "../chips/linkedText";
import { softBreakNodes } from "./softBreaksModel";
import { BareReferenceChip } from "../chips/BareReferenceChip";
import { textLinks } from "../chips/paths";
import {
  commitReferences,
  githubReferences,
  type CommitReference,
  type GithubReference,
} from "../../../githubReferences";
import { StartedSessionChip } from "../started/StartedSessionCard";
import { splitMentions } from "../started/startedSessions";
import { splitSkillText } from "./skillWords";
import { SkillWord } from "./SkillWord";
import { TimeHover } from "./timeHover";
import { splitTimeTokens } from "./timeHoverModel";
import type { InlineOptions } from "./inlineMarkdown";

const NO_REPOSITORY = "-/-";

function linkedGithubText(
  text: string,
  key: string,
  repository?: string,
  enabled = true,
  quietCommits = false,
  bare = true,
): ReactNode[] {
  if (!enabled) return linkedText(text, key);
  // A pull request address, so the chip opens the pull request card (an issue redirects there);
  // a commit (`abc1234`, `owner/repo@abc1234`) opens its GitHub page. In reading order; a commit
  // inside a reference, a URL or a path (`https://x.test/app.js?v=3a7bd3e2`) is part of it.
  // With no repository, a bare `#N` still goes to BareReferenceChip, which links it only when the
  // transcript names its repository.
  const issues = githubReferences(text, repository ?? NO_REPOSITORY, "pull", true);
  const commits = quietCommits ? quietCommitReferences(text, issues, repository) : commitReferences(text, repository);
  // A commit, a bare `#N` or a short name's `name#N` inside a URL or a path
  // (`https://x.test/?q=#12`, `?repo=cmux#3`) is part of it.
  const loose = (issue: GithubReference) => Boolean(issue.bare) || !issue.text.includes("/");
  const spans = commits.length || issues.some(loose) ? textLinks(text) : [];
  const outside = (ref: { start: number; end: number }) =>
    !spans.some((span) => ref.start < span.end && span.start < ref.end);
  const refs = [
    ...issues.filter((issue) => !loose(issue) || ((bare || !issue.bare) && outside(issue))),
    ...commits.filter(outside),
  ]
    .sort((a, b) => a.start - b.start)
    .filter((ref, index, all) => index === 0 || ref.start >= all[index - 1]!.end);
  if (!refs.length) return linkedText(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  refs.forEach((reference, index) => {
    if (reference.start > at) out.push(...linkedText(text.slice(at, reference.start), `${key}-${index}-before`));
    const sha = quietCommits && "sha" in reference;
    out.push(
      sha ? (
        reference.href ? (
          <a key={`${key}-${index}`} className="cv-sha" href={reference.href} rel="noreferrer">
            {reference.text}
          </a>
        ) : (
          <span key={`${key}-${index}`} className="cv-sha">
            {reference.text}
          </span>
        )
      ) : (
        <UrlChip
          key={`${key}-${index}`}
          href={reference.href}
          icon={<GitHubMark size={14} className="cv-link__icon cv-link__icon--gh" />}
        >
          {reference.text}
        </UrlChip>
      ),
    );
    // A bare `#N` names the repository the transcript's evidence says, not only `repository`.
    if ("bare" in reference && reference.bare)
      out[out.length - 1] = (
        <BareReferenceChip
          key={`${key}-${index}`}
          number={reference.bare}
          href={repository ? reference.href : undefined}
          text={reference.text}
        />
      );
    at = reference.end;
  });
  if (at < text.length) out.push(...linkedText(text.slice(at), `${key}-after`));
  return out;
}

/// Every commit SHA in `text` (an agent's message): each links to its commit in the repository it
/// names (`owner/repo@sha`), else that of the nearest reference before it in the same text
/// (`hq#2563 (db0677c6)` is a cmuxterm-hq commit), else `repository`; with none it is text.
function quietCommitReferences(text: string, issues: GithubReference[], repository?: string): CommitReference[] {
  return commitReferences(text, undefined, true).map((commit) => {
    if (commit.href) return commit;
    const before = issues.filter((issue) => issue.end <= commit.start).at(-1);
    const repo = before ? /^https:\/\/github\.com\/([^/]+\/[^/]+)\//.exec(before.href)?.[1] : repository;
    const text = commit.sha.length > 10 ? commit.sha.slice(0, 8) : commit.text;
    return repo ? { ...commit, text, href: `https://github.com/${repo}/commit/${commit.sha}` } : { ...commit, text };
  });
}

/// Plain prose: a started chat's name is its chip; the rest links GitHub references and URLs.
export function proseText(text: string, key: string, opts: InlineOptions): ReactNode[] {
  const out: ReactNode[] = [];
  let index = 0;
  for (const part of splitTimeTokens(text)) {
    if (typeof part !== "string") {
      out.push(<TimeHover key={`${key}-${index++}`} token={part} />);
      continue;
    }
    const pieces = opts.started?.mentions.length ? splitMentions(part, opts.started.mentions) : [part];
    out.push(
      ...pieces.flatMap((piece): ReactNode[] => {
        const current = `${key}-${index++}`;
        if (typeof piece === "string" && opts.skills?.size) {
          const words = splitSkillText(piece, opts.skills);
          if (words.length > 1 || typeof words[0] !== "string")
            return words.flatMap((word, at): ReactNode[] =>
              typeof word === "string"
                ? softBreakNodes(
                    linkedGithubText(
                      word,
                      `${current}-${at}`,
                      opts.githubRepository,
                      opts.linkGithubReferences !== false,
                      opts.commits === "quiet",
                      opts.linkBareReferences !== false,
                    ),
                    `${current}-${at}`,
                  )
                : [<SkillWord key={`${current}-${at}`} {...word} />],
            );
        }
        return typeof piece === "string"
          ? softBreakNodes(
              linkedGithubText(
                piece,
                current,
                opts.githubRepository,
                opts.linkGithubReferences !== false,
                opts.commits === "quiet",
                opts.linkBareReferences !== false,
              ),
              current,
            )
          : [
              <StartedSessionChip
                key={current}
                mention={piece.mention}
                text={piece.text}
                onOpen={opts.started!.open}
              />,
            ];
      }),
    );
  }
  return out;
}
