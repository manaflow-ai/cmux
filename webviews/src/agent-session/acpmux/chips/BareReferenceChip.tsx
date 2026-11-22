// A bare `#N` in a reply or an agent's message: the pull request chip of the repository the
// transcript's evidence names (conversation/bareReferences.ts), not always the chat folder's.
// When N is a pull request in two or more of the candidates, the chip says whose it is
// (`leo-workspace#843`).
import { useContext } from "react";
import {
  ReferenceScopeContext,
  candidateRepositories,
  chooseRepository,
  namedRepository,
} from "../conversation/bareReferences";
import { GitHubMark } from "../conversation/icons";
import { UrlChip } from "./LinkChips";
import { usePullRequestsExist } from "./referenceExistence";

const address = (repository: string, number: number) => `https://github.com/${repository}/pull/${number}`;
const NO_URLS: readonly string[] = [];

/// `href` is the folder's (or the transcript's) address for the number: rule d's. Without one, or
/// when the number is out of every candidate's range (rule 4), the number is linked only when the
/// transcript names its repository.
export function BareReferenceChip({ number, href, text }: { number: number; href?: string; text: string }) {
  const scope = useContext(ReferenceScopeContext);
  const fallback = href && /^https:\/\/github\.com\/([^/]+\/[^/]+)\//.exec(href)?.[1];
  const named = namedRepository(number, scope);
  const candidates = !named && fallback ? candidateRepositories(fallback, scope, number) : [];
  // Rule d stands for the folder's repository alone, so one candidate is asked about only when the
  // folder's is out of range (rule 4) and the cache must say the chat's repository has N.
  const folderFirst = Boolean(fallback) && candidates[0] === fallback;
  const existing = usePullRequestsExist(
    candidates.length > (folderFirst ? 1 : 0) ? candidates.map((repository) => address(repository, number)) : NO_URLS,
  );
  const choice = named
    ? { repository: named, alternatives: [] }
    : candidates.length
      ? chooseRepository(candidates, existing, fallback || undefined)
      : undefined;
  const ambiguous = Boolean(choice?.alternatives.length);
  if (!choice) return text;
  return (
    <UrlChip
      href={address(choice.repository, number)}
      icon={<GitHubMark size={14} className="cv-link__icon cv-link__icon--gh" />}
    >
      {ambiguous ? `${choice.repository.split("/")[1]}#${number}` : text}
    </UrlChip>
  );
}
