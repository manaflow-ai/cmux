// Session Info's Changes, after Claude Code desktop's: every pull request the chat opened or
// mutated, open ones first, then the ended ones, newest first within each. A row is its
// title, then `repo #N`, the lines it changes (a hover splits them into Code, Tests, Generated and
// Docs), its comments, and at the end its failing checks (with how many already fail on its base
// branch, dimmed: those are not this pull request's) or a green dot when they pass. Its state is
// the glyph's shape and color alone (PullRequestGlyph), never a word. A click opens it beside the
// chat; its ⋯ menu also copies the link or the reference. Five rows show, then Show more.
import { Counts } from "../changes/Counts";
import { copyText } from "../conversation/clipboard";
import { pullRequestStateSince, type HeaderPullRequest } from "../header/headerState";
import { useId, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Tooltip } from "../../../ui/Tooltip";
import { GitHubMark } from "../conversation/icons";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";
import type { SummaryPullRequest } from "../summary/sessionSummary";
import { PullRequestGlyph, type PullRequestGlyphState } from "./PullRequestGlyph";

const ROW_ICON = rowIconSize(12);
/// Rows shown before Show more (Claude Code desktop's Changes shows five).
export const CHANGES_SHOWN = 5;

/// Lines a pull request adds and removes in one kind of file.
export type LineCounts = { readonly additions: number; readonly deletions: number };
export type ChangeKind = "code" | "tests" | "generated" | "docs";
const KINDS: readonly ChangeKind[] = ["code", "tests", "generated", "docs"];
const KIND_LABELS: Record<ChangeKind, StringKey> = {
  code: "sessionInfo.changes.code",
  tests: "sessionInfo.changes.tests",
  generated: "sessionInfo.changes.generated",
  docs: "sessionInfo.changes.docs",
};

/// What the App knows of a pull request now; any field it has not read is left out.
export type SessionInfoPullRequestStatus = {
  title?: string;
  /// `open`, `draft`, `merged` or `closed`.
  state?: string;
  /// `mergeable`, `conflicting`, or empty while GitHub works it out.
  mergeable?: string;
  additions?: number;
  deletions?: number;
  /// The same lines split by the kind of file they are in.
  breakdown?: Partial<Record<ChangeKind, LineCounts>>;
  /// The checks summed: `failing`, `pending`, `passing` or `none`.
  checks?: string;
  /// How many checks fail, and how many of those fail on the base branch's head too.
  failing?: number;
  failingOnBase?: number;
  /// How many comments and reviews it has.
  comments?: number;
  /// Who owns it: the agent or person the App names (a login, a lane's callsign).
  owner?: string;
  /// When the App first read it in `state` (epoch ms).
  since?: number;
};

/// The header's pull request (the chat folder's, read live by the App) as a status.
export function headerStatus(pr: HeaderPullRequest | undefined): Record<string, SessionInfoPullRequestStatus> {
  if (!pr) return {};
  const failing = pr.checkList.filter((check) => check.state === "failed").length;
  return {
    [pr.url]: {
      title: pr.title || undefined,
      state: pr.state || undefined,
      mergeable: pr.mergeable || undefined,
      checks: pr.checks.state,
      ...(failing > 0 ? { failing } : {}),
      since: pullRequestStateSince(pr.url),
    },
  };
}

const ABBREVIATE_FROM = 10_000;

/** A row count (lines, comments, failing checks) short enough for a narrow row: 1,284, then 12.3K,
 *  4.6M ... 9Q. Below 10,000 the number is exact; above it, screen readers get the exact one. */
export function formatCount(count: number): string {
  if (count < ABBREVIATE_FROM) return count.toLocaleString();
  const units = ["K", "M", "B", "T", "Q"];
  let value = count;
  let unit = "";
  for (const candidate of units) {
    if (value < 1000) break;
    value /= 1000;
    unit = candidate;
  }
  const rounded = value >= 100 ? Math.round(value) : value.toFixed(1).replace(/\.0$/, "");
  return `${rounded}${unit}`;
}

const CHECK_LABELS: Record<string, StringKey> = {
  passing: "rail.checksPassing",
  pending: "rail.checksPending",
};

/// The state glyph's label, for screen readers only: the row shows no state word.
const STATE_LABELS: Record<PullRequestGlyphState, StringKey> = {
  open: "sessionInfo.changes.open",
  draft: "sessionInfo.changes.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
  conflicting: "header.prConflicts",
};

/// What the row shows of `pr`: the App's read when it is newer than what the chat did.
export function rowState(pr: SummaryPullRequest, live: SessionInfoPullRequestStatus): string {
  // A merge the chat ran is final. A close wins until a later read differs (a reopen). An open
  // one defers to the App.
  if (pr.state === "closed") {
    const after = live.since !== undefined && pr.closedAt !== undefined && live.since > pr.closedAt;
    return after && live.state ? live.state : "closed";
  }
  return pr.state !== "open" ? pr.state : (live.state ?? "open");
}

/// The glyph a row draws: its state, and an open one GitHub can't merge for conflicts is red.
export function glyphState(pr: SummaryPullRequest, live: SessionInfoPullRequestStatus): PullRequestGlyphState {
  const state = rowState(pr, live);
  if (state === "merged" || state === "closed" || state === "draft") return state;
  return live.mergeable === "conflicting" ? "conflicting" : "open";
}

const ended = (state: PullRequestGlyphState) => state === "merged" || state === "closed";

/// Changes contains only pull requests this session created or mutated. Read-only PR and issue
/// references stay in Sources, even after the App has read them as pull requests.
export const visibleChanges = (
  pullRequests: readonly SummaryPullRequest[],
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>,
): SummaryPullRequest[] => {
  void statuses;
  return pullRequests.filter((pr) => pr.kind !== "issue" && (pr.opened || pr.changed === true));
};

/// The rows in Claude's order: the ones still open (drafts and conflicting ones included) first,
/// then the merged and closed, the most recently touched or named first within each.
export function changesOrder(
  pullRequests: readonly SummaryPullRequest[],
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>,
): SummaryPullRequest[] {
  const newest = pullRequests
    .map((pr, index) => ({ pr, index, at: pr.touched ?? index }))
    .sort((a, b) => b.at - a.at || b.index - a.index)
    .map(({ pr }) => pr);
  const done = (pr: SummaryPullRequest) => ended(glyphState(pr, statuses[pr.url] ?? {}));
  return [...newest.filter((pr) => !done(pr)), ...newest.filter(done)];
}

export function ChangesSection({
  pullRequests,
  statuses,
  onOpenBeside,
  onDismiss,
}: {
  /// In any order: Changes sorts them (changesOrder).
  pullRequests: readonly SummaryPullRequest[];
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>;
  /// Dismisses the PR's composer affordance while leaving the Changes row visible.
  onDismiss?: (url: string) => void;
  /// Opens a pull request in the browser beside the chat; the menu item hides without it, and a
  /// row's click follows its link instead.
  onOpenBeside?: (url: string) => void;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const ordered = changesOrder(pullRequests, statuses);
  const folds = ordered.length > CHANGES_SHOWN;
  const shown = folds && !all ? ordered.slice(0, CHANGES_SHOWN) : ordered;
  return (
    <>
      <ul className="acpmux-session-info-list" data-section="changes">
        {shown.map((pr) => (
          <PullRequestRow
            key={pr.url}
            pr={pr}
            live={statuses[pr.url] ?? {}}
            onOpenBeside={onOpenBeside}
            onDismiss={onDismiss}
          />
        ))}
      </ul>
      {folds && (
        <button
          type="button"
          className="acpmux-session-info-fold acpmux-session-info-pr-fold"
          aria-expanded={all}
          onClick={() => setAll(!all)}
        >
          {t(all ? "sessionInfo.changes.showLess" : "sessionInfo.changes.showMore")}
        </button>
      )}
    </>
  );
}

function PullRequestRow({
  pr,
  live,
  onOpenBeside,
  onDismiss,
}: {
  pr: SummaryPullRequest;
  live: SessionInfoPullRequestStatus;
  onOpenBeside?: (url: string) => void;
  onDismiss?: (url: string) => void;
}) {
  const t = useT();
  const hover = useHoverCard();
  const site = useSiteInfo(pr.url);
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const card = useId();
  const state = glyphState(pr, live);
  const title = live.title ?? pr.title;
  const repoName = pr.repo.split("/").pop() ?? pr.repo;
  const reference = `${pr.repo}#${pr.number}`;
  const checks = ended(state) ? undefined : live.checks;
  const failing = ended(state) ? 0 : (live.failing ?? (checks === "failing" ? -1 : 0));
  const onBase = Math.min(Math.max(0, live.failingOnBase ?? 0), Math.max(0, failing));
  const comments = live.comments ?? 0;
  const stateLabel = t(STATE_LABELS[state]);
  return (
    // The whole row lights on hover, so the whole row is one target: the link's hit area stretches
    // over the row's own gap and padding (sessionInfo.css), with only the ⋯ button above it. The
    // owner chip is inside the link and opens the pull request too; a label, not its own control.
    <li className="acpmux-session-info-pr" data-state={state}>
      <a
        ref={setAnchor}
        className="acpmux-session-info-pr__link"
        href={pr.url}
        aria-describedby={hover.open ? card : undefined}
        onClick={(event) => {
          if (!onOpenBeside || event.metaKey || event.ctrlKey || event.shiftKey) return;
          event.preventDefault();
          onOpenBeside(pr.url);
        }}
        {...hover.trigger}
      >
        {/* tooltip-allow: the state glyph shows no text; its label is for screen readers only */}
        <span className="acpmux-session-info-pr__icon" title={stateLabel}>
          <PullRequestGlyph state={state} size={ROW_ICON} />
          <span className="acpmux-session-info-sr-only">{stateLabel}</span>
        </span>
        <span className="acpmux-session-info-pr__text">
          {/* The owner sits beside the title, so the line under it keeps the row's whole width. */}
          <span className="acpmux-session-info-pr__head">
            <span className="acpmux-session-info-pr__title">{title || `#${pr.number}`}</span>
            {live.owner && (
              <span className="acpmux-session-info-pr__owner">
                <span className="acpmux-session-info-sr-only">{t("sessionInfo.changes.ownerLabel")} </span>
                {live.owner}
              </span>
            )}
          </span>
          <span className="acpmux-session-info-pr__line">
            <span className="acpmux-session-info-pr__ref">{`${repoName} #${pr.number}`}</span>
            {live.additions !== undefined && live.deletions !== undefined && (
              <LineTotals additions={live.additions} deletions={live.deletions} breakdown={live.breakdown} />
            )}
            {comments > 0 && (
              <span className="acpmux-session-info-pr__comments">
                <Icon name="agent.chat" size={12} />
                <span aria-hidden="true">{formatCount(comments)}</span>
                <span className="acpmux-session-info-sr-only">
                  {t("sessionInfo.changes.comments", { count: comments })}
                </span>
              </span>
            )}
            {failing !== 0 ? (
              <span className="acpmux-session-info-pr__checks" data-checks="failing">
                {/* "N failing" stays whole; the on-base share after it gives way first (sessionInfo.css). */}
                <span className="acpmux-session-info-pr__failing">
                  {failing <= 0 ? (
                    t("rail.checksFailing")
                  ) : failing < ABBREVIATE_FROM ? (
                    t("sessionInfo.changes.failing", { count: formatCount(failing) })
                  ) : (
                    <>
                      <span aria-hidden="true">
                        {t("sessionInfo.changes.failing", { count: formatCount(failing) })}
                      </span>
                      <span className="acpmux-session-info-sr-only">
                        {t("sessionInfo.changes.failing", { count: failing })}
                      </span>
                    </>
                  )}
                </span>
                {onBase > 0 && (
                  <span className="acpmux-session-info-pr__base">
                    {" "}
                    {onBase < ABBREVIATE_FROM ? (
                      t("sessionInfo.changes.failingOnBase", { count: formatCount(onBase) })
                    ) : (
                      <>
                        <span aria-hidden="true">
                          {t("sessionInfo.changes.failingOnBase", { count: formatCount(onBase) })}
                        </span>
                        <span className="acpmux-session-info-sr-only">
                          {t("sessionInfo.changes.failingOnBase", { count: onBase })}
                        </span>
                      </>
                    )}
                  </span>
                )}
              </span>
            ) : checks && CHECK_LABELS[checks] ? (
              // tooltip-allow: the checks mark shows no text; its label is for screen readers only
              <span className="acpmux-session-info-pr__checks" data-checks={checks} title={t(CHECK_LABELS[checks]!)}>
                <span className="acpmux-session-info-sr-only">{t(CHECK_LABELS[checks]!)}</span>
              </span>
            ) : null}
          </span>
        </span>
      </a>
      <LinkHoverCard
        id={card}
        href={pr.url}
        anchor={anchor}
        hover={hover}
        mark={<GitHubMark size={14} className="cv-chip__icon cv-chip__icon--gh" />}
        siteTitle={site?.title}
        pullRequest={{ repo: pr.repo, number: pr.number, title: title || undefined, state }}
        side="top"
      />
      <Menu>
        <MenuButton
          className="acpmux-session-info-icon-button acpmux-session-info-pr__more"
          label={t("sessionInfo.changes.more", { reference })}
          aria-haspopup="menu"
        >
          <Icon name="action.more" size={14} />
        </MenuButton>
        <MenuPopup
          className="acpmux-session-info-menu"
          label={t("sessionInfo.changes.actions", { reference })}
          align="end"
        >
          {onOpenBeside && (
            <MenuItem className="acpmux-session-info-menu__item" onSelect={() => onOpenBeside(pr.url)}>
              {t("sessionInfo.changes.openBeside")}
            </MenuItem>
          )}
          <MenuItem className="acpmux-session-info-menu__item" onSelect={() => void copyText(pr.url)}>
            {t("sessionInfo.changes.copyLink")}
          </MenuItem>
          <MenuItem className="acpmux-session-info-menu__item" onSelect={() => void copyText(reference)}>
            {t("sessionInfo.changes.copyReference")}
          </MenuItem>
          {onDismiss && (
            <MenuItem className="acpmux-session-info-menu__item" onSelect={() => onDismiss(pr.url)}>
              {t("prDock.dismiss", { number: pr.number })}
            </MenuItem>
          )}
        </MenuPopup>
      </Menu>
    </li>
  );
}

/// The +/- totals; with a breakdown, a hover or focus shows it by kind of file.
function LineTotals({
  additions,
  deletions,
  breakdown,
}: {
  additions: number;
  deletions: number;
  breakdown?: Partial<Record<ChangeKind, LineCounts>>;
}) {
  const t = useT();
  // Shortened like the comment count, so the comments and checks after it keep their room.
  const counts = (
    <Counts
      additions={additions}
      deletions={deletions}
      format={formatCount}
      label={
        Math.max(additions, deletions) < ABBREVIATE_FROM ? undefined : (
          <span className="acpmux-session-info-sr-only">{`+${additions} -${deletions}`}</span>
        )
      }
    />
  );
  const kinds = KINDS.filter((kind) => breakdown?.[kind]);
  if (kinds.length === 0) return counts;
  return (
    <Tooltip /* tooltip-allow: it splits the totals by kind of file, which the row does not show */
      className="acpmux-session-info-breakdown"
      label={
        <span className="acpmux-session-info-breakdown__rows">
          {kinds.map((kind) => (
            <span key={kind} className="acpmux-session-info-breakdown__row">
              <span>{t(KIND_LABELS[kind])}</span>
              <Counts additions={breakdown![kind]!.additions} deletions={breakdown![kind]!.deletions} />
            </span>
          ))}
        </span>
      }
    >
      <span className="acpmux-session-info-pr__counts">{counts}</span>
    </Tooltip>
  );
}
