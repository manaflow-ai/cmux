// The Inspector's Changes (Claude Code desktop's Changes): every pull request the chat opened or
// touched, newest first. A row is a link to the pull request and shows its state icon, title and
// `repo #N`, then what the App has read of it: the lines it changes (a hover splits them into Code,
// Tests, Generated and Docs), its failing checks with how many already fail on its base branch
// (dimmed: those are not this pull request's), and its owner. Its ⋯ menu copies the link or the
// reference and opens it beside the chat. The list scrolls inside the section; no row is hidden
// behind a cap.
import { Counts } from "../changes/Counts";
import { copyText } from "../conversation/clipboard";
import { pullRequestStateSince, type HeaderPullRequest } from "../header/headerState";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Tooltip } from "../../../ui/Tooltip";
import type { SummaryPullRequest } from "../summary/sessionSummary";

const ROW_ICON = rowIconSize(12);

/// Lines a pull request adds and removes in one kind of file.
export type LineCounts = { readonly additions: number; readonly deletions: number };
export type ChangeKind = "code" | "tests" | "generated" | "docs";
const KINDS: readonly ChangeKind[] = ["code", "tests", "generated", "docs"];
const KIND_LABELS: Record<ChangeKind, StringKey> = {
  code: "chatInspector.changes.code",
  tests: "chatInspector.changes.tests",
  generated: "chatInspector.changes.generated",
  docs: "chatInspector.changes.docs",
};

/// What the App knows of a pull request now; any field it has not read is left out.
export type InspectorPullRequestStatus = {
  title?: string;
  /// `open`, `draft`, `merged` or `closed`.
  state?: string;
  additions?: number;
  deletions?: number;
  /// The same lines split by the kind of file they are in.
  breakdown?: Partial<Record<ChangeKind, LineCounts>>;
  /// The checks summed: `failing`, `pending`, `passing` or `none`.
  checks?: string;
  /// How many checks fail, and how many of those fail on the base branch's head too.
  failing?: number;
  failingOnBase?: number;
  /// Who owns it: the agent or person the App names (a login, a lane's callsign).
  owner?: string;
  /// When the App first read it in `state` (epoch ms).
  since?: number;
};

/// The header's pull request (the chat folder's, read live by the App) as a status.
export function headerStatus(pr: HeaderPullRequest | undefined): Record<string, InspectorPullRequestStatus> {
  if (!pr) return {};
  const failing = pr.checkList.filter((check) => check.state === "failed").length;
  return {
    [pr.url]: {
      title: pr.title || undefined,
      state: pr.state || undefined,
      checks: pr.checks.state,
      ...(failing > 0 ? { failing } : {}),
      since: pullRequestStateSince(pr.url),
    },
  };
}

const CHECK_LABELS: Record<string, StringKey> = {
  passing: "rail.checksPassing",
  pending: "rail.checksPending",
};

const STATE_LABELS: Record<string, StringKey> = {
  open: "chatInspector.changes.open",
  draft: "chatInspector.changes.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};

/// What the row shows of `pr`: the App's read when it is newer than what the chat did.
export function rowState(pr: SummaryPullRequest, live: InspectorPullRequestStatus): string {
  // A merge the chat ran is final. A close wins until a later read differs (a reopen). An open
  // one defers to the App.
  if (pr.state === "closed") {
    const after = live.since !== undefined && pr.closedAt !== undefined && live.since > pr.closedAt;
    return after && live.state ? live.state : "closed";
  }
  return pr.state !== "open" ? pr.state : (live.state ?? "open");
}

export function ChangesSection({
  pullRequests,
  statuses,
  onOpenBeside,
}: {
  /// Oldest first, as sessionSummary reads them.
  pullRequests: readonly SummaryPullRequest[];
  statuses: Readonly<Record<string, InspectorPullRequestStatus>>;
  /// Opens a pull request in the browser beside the chat; the menu item hides without it.
  onOpenBeside?: (url: string) => void;
}) {
  const newest = [...pullRequests].reverse();
  return (
    <ul className="acpmux-chat-inspector-list acpmux-chat-inspector-scroll" data-section="changes">
      {newest.map((pr) => (
        <PullRequestRow key={pr.url} pr={pr} live={statuses[pr.url] ?? {}} onOpenBeside={onOpenBeside} />
      ))}
    </ul>
  );
}

function PullRequestRow({
  pr,
  live,
  onOpenBeside,
}: {
  pr: SummaryPullRequest;
  live: InspectorPullRequestStatus;
  onOpenBeside?: (url: string) => void;
}) {
  const t = useT();
  const state = rowState(pr, live);
  const title = live.title ?? pr.title;
  const repoName = pr.repo.split("/").pop() ?? pr.repo;
  const reference = `${pr.repo}#${pr.number}`;
  const ended = state === "merged" || state === "closed";
  const checks = ended ? undefined : live.checks;
  const failing = ended ? 0 : (live.failing ?? (checks === "failing" ? -1 : 0));
  const onBase = Math.min(Math.max(0, live.failingOnBase ?? 0), Math.max(0, failing));
  const stateLabel = t(STATE_LABELS[state] ?? "chatInspector.changes.open");
  return (
    <li className="acpmux-chat-inspector-pr" data-state={state}>
      <a className="acpmux-chat-inspector-pr__link" href={pr.url}>
        {/* tooltip-allow: the state icon shows no text; its label is for screen readers only */}
        <span className="acpmux-chat-inspector-pr__icon" title={stateLabel}>
          <Icon name="git.pullrequest" size={ROW_ICON} row />
          <span className="acpmux-chat-inspector-sr-only">{stateLabel}</span>
        </span>
        <span className="acpmux-chat-inspector-pr__text">
          <span className="acpmux-chat-inspector-pr__title">{title || `#${pr.number}`}</span>
          <span className="acpmux-chat-inspector-pr__line">
            <span className="acpmux-chat-inspector-pr__ref">{`${repoName} #${pr.number}`}</span>
            {live.additions !== undefined && live.deletions !== undefined && (
              <LineTotals additions={live.additions} deletions={live.deletions} breakdown={live.breakdown} />
            )}
            {ended ? (
              <span className="acpmux-chat-inspector-pr__state">{stateLabel}</span>
            ) : failing !== 0 ? (
              <span className="acpmux-chat-inspector-pr__checks" data-checks="failing">
                {failing > 0 ? t("chatInspector.changes.failing", { count: failing }) : t("rail.checksFailing")}
                {onBase > 0 && (
                  <span className="acpmux-chat-inspector-pr__base">
                    {" "}
                    {t("chatInspector.changes.failingOnBase", { count: onBase })}
                  </span>
                )}
              </span>
            ) : checks && CHECK_LABELS[checks] ? (
              // tooltip-allow: the checks mark shows no text; its label is for screen readers only
              <span className="acpmux-chat-inspector-pr__checks" data-checks={checks} title={t(CHECK_LABELS[checks]!)}>
                <span className="acpmux-chat-inspector-sr-only">{t(CHECK_LABELS[checks]!)}</span>
              </span>
            ) : null}
          </span>
        </span>
      </a>
      {live.owner && (
        <span className="acpmux-chat-inspector-pr__owner">
          <span className="acpmux-chat-inspector-sr-only">{t("chatInspector.changes.ownerLabel")} </span>
          {live.owner}
        </span>
      )}
      <Menu>
        <MenuButton
          className="acpmux-chat-inspector-icon-button acpmux-chat-inspector-pr__more"
          label={t("chatInspector.changes.more", { reference })}
          aria-haspopup="menu"
        >
          <Icon name="action.more" size={14} />
        </MenuButton>
        <MenuPopup
          className="acpmux-chat-inspector-menu"
          label={t("chatInspector.changes.actions", { reference })}
          align="end"
        >
          {onOpenBeside && (
            <MenuItem className="acpmux-chat-inspector-menu__item" onSelect={() => onOpenBeside(pr.url)}>
              {t("chatInspector.changes.openBeside")}
            </MenuItem>
          )}
          <MenuItem className="acpmux-chat-inspector-menu__item" onSelect={() => void copyText(pr.url)}>
            {t("chatInspector.changes.copyLink")}
          </MenuItem>
          <MenuItem className="acpmux-chat-inspector-menu__item" onSelect={() => void copyText(reference)}>
            {t("chatInspector.changes.copyReference")}
          </MenuItem>
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
  const counts = <Counts additions={additions} deletions={deletions} />;
  const kinds = KINDS.filter((kind) => breakdown?.[kind]);
  if (kinds.length === 0) return counts;
  return (
    <Tooltip /* tooltip-allow: it splits the totals by kind of file, which the row does not show */
      className="acpmux-chat-inspector-breakdown"
      label={
        <span className="acpmux-chat-inspector-breakdown__rows">
          {kinds.map((kind) => (
            <span key={kind} className="acpmux-chat-inspector-breakdown__row">
              <span>{t(KIND_LABELS[kind])}</span>
              <Counts additions={breakdown![kind]!.additions} deletions={breakdown![kind]!.deletions} />
            </span>
          ))}
        </span>
      }
    >
      <span className="acpmux-chat-inspector-pr__counts">{counts}</span>
    </Tooltip>
  );
}
