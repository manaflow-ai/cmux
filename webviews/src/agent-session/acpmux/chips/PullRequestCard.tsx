// A pull request's hover card (Leo 2026-10-20): a cut-off pull request title is worth a hover, on
// a styled card rather than the system tooltip. The pull request bars above the composer
// (summary/PullRequestDock.tsx) and a pull request chip in a reply (LinkChips.tsx UrlChip) show
// it: the full title, owner/repo#N, the state, the author and the checks, as the user's GitHub CLI
// reads them (`pr.inspect`, pullRequestStore.ts). Until the host answers, and when it can't, the
// card shows what the chat already knows.
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { usePullRequestInfo } from "./pullRequestStore";

const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};

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

/// What the page knows before gh answers: the bar's or chip's own text.
export type KnownPullRequest = { repo: string; number: number; title?: string; state?: string };

/// The card's content; its frame (AnchoredCard) belongs to the caller. `open` asks the host.
export function PullRequestCardBody({ url, known, open }: { url: string; known: KnownPullRequest; open: boolean }) {
  const t = useT();
  // gh is asked about the plain address, as the host takes it.
  const read = usePullRequestInfo(pullRequestRef(url)?.url ?? url, open);
  const title = read?.title || known.title;
  const state = read?.state || known.state;
  const checks = read?.checks;
  const failed = read?.checkList?.filter((check) => check.state === "failed").length || 0;
  return (
    <div className="acpmux-pr-card__body">
      {title && <div className="acpmux-pr-card__title">{title}</div>}
      <div className="acpmux-pr-card__facts">
        <Icon name="git.pullrequest" size={13} />
        <span className="acpmux-pr-card__ref">
          {known.repo}#{known.number}
        </span>
        {state && (
          <span className="acpmux-pr-card__state" data-state={state}>
            {BADGES[state] ? t(BADGES[state]!) : state}
          </span>
        )}
        {read?.author && <span className="acpmux-pr-card__author">{t("prCard.author", { author: read.author })}</span>}
      </div>
      {checks && checks.total > 0 && (
        <div className="acpmux-pr-card__checks" data-state={checks.state}>
          {failed > 0 || checks.state === "failing"
            ? t("prCard.checksFailing", {
                passed: checks.passed,
                total: checks.total,
                failed: failed || checks.total - checks.passed,
              })
            : t("prCard.checks", { passed: checks.passed, total: checks.total })}
        </div>
      )}
      {checks && checks.total === 0 && <div className="acpmux-pr-card__checks">{t("header.prNoChecks")}</div>}
    </div>
  );
}
