// A session's status line (on a started chat's row, StartedSessionCard.tsx, and on its hover card),
// as Claude Code's PR rows read: the status first, its glyph and word in its colour (a running one
// the bare working spinner), then `· repo #N` (and how many more) in the dim colour. Styled in
// startedSessions.css.
import { Icon } from "../icons/Icon";
import { useT, type StringKey } from "../i18n";
import { Spinner } from "../conversation/icons";
import type { SessionStatus, StartedPullRequests } from "./startedSessions";
import "./startedSessions.css";

/// Each status's word and glyph; running draws the bare working spinner instead.
const STATUS: Record<SessionStatus, { word: StringKey; glyph?: string }> = {
  waiting: { word: "home.needsInput", glyph: "status.needsinput" },
  failed: { word: "subagents.state.failed", glyph: "status.error" },
  running: { word: "subagents.state.running" },
  unread: { word: "sidebar.markUnread", glyph: "status.dot" },
  done: { word: "subagents.state.completed", glyph: "status.complete" },
  ready: { word: "started.prReady", glyph: "git.pullrequest" },
  failing: { word: "started.checksFailed", glyph: "git.pullrequest" },
  open: { word: "header.prBadge.open", glyph: "git.pullrequest" },
  draft: { word: "header.prBadge.draft", glyph: "git.pullrequest" },
  merged: { word: "header.prBadge.merged", glyph: "git.pullrequest" },
  closed: { word: "header.prBadge.closed", glyph: "git.pullrequest" },
};

/// `repo #N`, or `#N` when acpmux names no repository.
export const pullRequestName = (prs: StartedPullRequests): string =>
  prs.repo ? `${prs.repo} #${prs.number}` : `#${prs.number}`;

/// The status line. Without a status (a done chat on its row), only the pull request.
export function SessionStatusLine({
  status,
  pullRequests,
}: {
  status: SessionStatus | undefined;
  pullRequests?: StartedPullRequests | undefined;
}) {
  const t = useT();
  return (
    <span className="acpmux-session-status-line">
      {status && (
        <span className="acpmux-session-status" data-status={status}>
          {STATUS[status].glyph ? (
            <Icon name={STATUS[status].glyph!} size={12} />
          ) : (
            <Spinner size={12} className="acpmux-session-status-spinner" />
          )}
          <span>{t(STATUS[status].word)}</span>
        </span>
      )}
      {pullRequests && (
        <span className="acpmux-session-status-pr">
          <span>{pullRequestName(pullRequests)}</span>
          {pullRequests.count > 1 && <span>{t("started.morePullRequests", { count: pullRequests.count - 1 })}</span>}
        </span>
      )}
    </span>
  );
}
