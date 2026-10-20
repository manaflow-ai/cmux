// The session rail's Changes card body (Claude Code desktop's Changes): each pull request the
// session opened, newest first, with its title, repository and number, its line counts and how
// its checks stand when the App knows them. A row opens the pull request. Five show and the rest
// wait behind Show more.
import { useRef, useState } from "react";
import { Counts } from "../changes/Counts";
import type { HeaderPullRequest } from "../header/headerState";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SummaryPullRequest } from "./sessionSummary";

const SHOWN = 5;
const ROW_ICON = rowIconSize(12);

/// What the App knows of a pull request now; any field it has not read is left out.
export type RailPullRequestStatus = {
  title?: string;
  /// `open`, `draft`, `merged` or `closed`.
  state?: string;
  additions?: number;
  deletions?: number;
  /// The checks summed: `failing`, `pending`, `passing` or `none`.
  checks?: string;
};

/// The header's pull request (the chat folder's, read live by the App) as a rail status.
export function headerStatus(pr: HeaderPullRequest | undefined): Record<string, RailPullRequestStatus> {
  if (!pr) return {};
  return { [pr.url]: { title: pr.title || undefined, state: pr.state, checks: pr.checks.state } };
}

const CHECK_LABELS: Record<string, StringKey> = {
  passing: "rail.checksPassing",
  pending: "rail.checksPending",
};

export function RailChanges({
  pullRequests,
  statuses,
}: {
  pullRequests: readonly SummaryPullRequest[];
  statuses: Readonly<Record<string, RailPullRequestStatus>>;
}) {
  const t = useT();
  const [expanded, setExpanded] = useState(false);
  /// For each pull request the chat closed: the App's state for it at the close, and whether a
  /// read since has said otherwise. Until one has, the close wins over an older read; after,
  /// the App's reads do (someone reopened it).
  const closes = useRef(new Map<string, { atClose?: string; since: boolean }>());
  const newest = [...pullRequests].reverse();
  const visible = expanded ? newest : newest.slice(0, SHOWN);
  return (
    <>
      <ul className="acpmux-rail-list">
        {visible.map((pr) => {
          const live = statuses[pr.url] ?? {};
          // A merge the chat ran is final. A close wins until a later read differs (a reopen).
          // An open one defers to the App.
          const state =
            pr.state === "closed"
              ? closedState(closes.current, pr.url, live.state)
              : pr.state !== "open"
                ? pr.state
                : (live.state ?? "open");
          const title = live.title ?? pr.title;
          const counted = live.additions !== undefined && live.deletions !== undefined;
          const checks = state === "open" || state === "draft" ? live.checks : undefined;
          return (
            <li key={pr.url}>
              <a className="acpmux-rail-pr" href={pr.url} data-state={state}>
                <Icon name="git.pullrequest" size={ROW_ICON} row />
                <span className="acpmux-rail-pr__text">
                  <span className="acpmux-rail-pr__title">{title || `#${pr.number}`}</span>
                  <span className="acpmux-rail-pr__line">
                    <span className="acpmux-rail-pr__ref">{`${pr.repo.split("/").pop()} #${pr.number}`}</span>
                    {counted && <Counts additions={live.additions!} deletions={live.deletions!} />}
                    {state === "merged" || state === "closed" ? (
                      <span className="acpmux-rail-pr__state">
                        {t(state === "merged" ? "header.prBadge.merged" : "header.prBadge.closed")}
                      </span>
                    ) : checks === "failing" ? (
                      <span className="acpmux-rail-pr__checks" data-checks="failing">
                        {t("rail.checksFailing")}
                      </span>
                    ) : checks && CHECK_LABELS[checks] ? (
                      <span className="acpmux-rail-pr__checks" data-checks={checks} title={t(CHECK_LABELS[checks]!)}>
                        <span className="acpmux-rail-sr">{t(CHECK_LABELS[checks]!)}</span>
                      </span>
                    ) : null}
                  </span>
                </span>
              </a>
            </li>
          );
        })}
      </ul>
      {newest.length > SHOWN && (
        <button
          type="button"
          className="acpmux-rail-more"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? t("prDock.less") : t("prDock.more", { count: newest.length - SHOWN })}
        </button>
      )}
    </>
  );
}

/// A closed pull request's state: `closed` until the App reads a state other than the one it had
/// when the chat closed it, then whatever the App reads.
function closedState(
  closes: Map<string, { atClose?: string; since: boolean }>,
  url: string,
  live: string | undefined,
): string {
  let close = closes.get(url);
  if (!close) closes.set(url, (close = { atClose: live, since: false }));
  if (live !== close.atClose) close.since = true;
  return close.since && live ? live : "closed";
}
