import { type ReactNode } from "react";
import { GitHubMark } from "./icons";
import { UrlChip } from "../chips/LinkChips";
import { linkedText } from "../chips/linkedText";
import { softBreakNodes } from "./softBreaksModel";
import { BareReferenceChip } from "../chips/BareReferenceChip";
import { proseIds } from "./proseIds";
import { StartedSessionChip } from "../started/StartedSessionCard";
import { splitMentions } from "../started/startedSessions";
import { splitSkillText } from "./skillWords";
import { SkillWord } from "./SkillWord";
import { TimeHover } from "./timeHover";
import { splitTimeTokens } from "./timeHoverModel";
import type { InlineOptions } from "./inlineMarkdown";
import { ClaimMark } from "./ClaimMark";
import { splitClaims } from "./claimMarks";

function linkedGithubText(
  text: string,
  key: string,
  repository?: string,
  enabled = true,
  quietCommits = false,
  bare = true,
): ReactNode[] {
  if (!enabled) return linkedText(text, key);
  // Every id the prose names, in reading order (proseIds.ts): a pull request or issue, a commit,
  // a nightly build or an Actions run. An id inside a URL or a path is part of it.
  const refs = proseIds(text, { repository, quietCommits, bare });
  if (!refs.length) return linkedText(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  refs.forEach((reference, index) => {
    if (reference.start > at) out.push(...linkedText(text.slice(at, reference.start), `${key}-${index}-before`));
    if (reference.kind === "commit" && reference.quiet)
      out.push(
        reference.href ? (
          <a key={`${key}-${index}`} className="cv-sha" href={reference.href} rel="noreferrer">
            {reference.text}
          </a>
        ) : (
          <span key={`${key}-${index}`} className="cv-sha">
            {reference.text}
          </span>
        ),
      );
    else if (reference.kind === "reference" && reference.bare)
      // A bare `#N` names the repository the transcript's evidence says, not only `repository`.
      out.push(
        <BareReferenceChip
          key={`${key}-${index}`}
          number={reference.bare}
          href={repository ? reference.href : undefined}
          text={reference.text}
        />,
      );
    else
      out.push(
        <UrlChip
          key={`${key}-${index}`}
          href={reference.href}
          reference={reference.kind === "run"}
          icon={<GitHubMark size={14} className="cv-link__icon cv-link__icon--gh" />}
        >
          {reference.text}
        </UrlChip>,
      );
    at = reference.end;
  });
  if (at < text.length) out.push(...linkedText(text.slice(at), `${key}-after`));
  return out;
}

/// Plain prose: a started chat's name is its chip; the rest links GitHub references and URLs.
export function proseText(text: string, key: string, opts: InlineOptions): ReactNode[] {
  // A checked claim's phrase draws inside its mark (ClaimMark.tsx), the rest as any prose.
  if (opts.claims?.length) {
    const pieces = splitClaims(text, opts.claims);
    if (pieces.length > 1 || typeof pieces[0] !== "string") {
      const plain = { ...opts, claims: undefined };
      return pieces.flatMap((piece, at): ReactNode[] =>
        typeof piece === "string"
          ? proseText(piece, `${key}-c${at}`, plain)
          : [
              <ClaimMark key={`${key}-c${at}`} claim={piece.claim}>
                {proseText(piece.text, `${key}-c${at}-t`, plain)}
              </ClaimMark>,
            ],
      );
    }
  }
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
