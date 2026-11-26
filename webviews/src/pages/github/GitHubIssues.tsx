// The GitHub page's issues view (GitHub integration audit, fix nine): a repository's issues and one
// issue with its comments, drawn in the pull request page's own header, section and timeline styles
// so the two read as one page. The list says what each issue is and where it stands (state,
// number, title, labels, author, comment count, last activity); a row opens the issue in place.
import { useCallback, useSyncExternalStore, type CSSProperties } from "react";
import { relativeTime } from "../../agent-session/acpmux/conversation/relativeTime";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../shared/i18n";
import { GitHubMarkdown } from "./GitHubMarkdown";
import type { IssuesStore } from "./issuesStore";
import type { GitHubIssue, GitHubIssueComment, GitHubIssueLabel } from "./types";

export function GitHubIssues({
  store,
  strings,
  now = Date.now,
}: {
  store: IssuesStore;
  strings: Strings;
  now?: () => number;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const open = useCallback((url: string) => store.openOnGitHub(url), [store]);
  const { view } = snapshot;
  if (!view) return null;
  if (view.kind === "list") {
    return (
      <main className="gh gh-issues" data-width="fill" aria-busy={snapshot.loading}>
        <header className="gh-head">
          <div className="gh-ref">
            <IssueGlyph />
            <span>{view.repo}</span>
          </div>
          <div className="gh-head-row">
            <h1 className="gh-title">{strings.t("github.issues")}</h1>
            <div className="gh-actions">
              <button type="button" className="gh-button" onClick={() => store.openOnGitHub()}>
                {strings.t("github.openOnGitHub")}
              </button>
            </div>
          </div>
          {snapshot.failure && (
            <p className="gh-failure" role="alert">
              {snapshot.issues ? snapshot.failure : strings.t("github.issues.failed")}
            </p>
          )}
        </header>
        <IssueList snapshot={snapshot} store={store} strings={strings} now={now} />
      </main>
    );
  }
  const { issue, comments = [] } = snapshot;
  const updatedAt = issue ? Date.parse(issue.updated_at) : Number.NaN;
  return (
    <main className="gh gh-issues" data-width="fill" aria-busy={snapshot.loading}>
      <header className="gh-head">
        <div className="gh-ref">
          <IssueGlyph issue={issue} />
          <span>
            {view.repo} #{view.number}
          </span>
          <button type="button" className="gh-fold gh-issues-back" onClick={() => store.openList()}>
            {strings.t("github.issues.back")}
          </button>
        </div>
        <div className="gh-head-row">
          <h1 className="gh-title">
            {issue?.title ||
              (snapshot.loading
                ? strings.t("github.issue.loading")
                : snapshot.failure
                  ? strings.t("github.issue.failed")
                  : "")}
          </h1>
          <div className="gh-actions">
            <button type="button" className="gh-button" onClick={() => store.openOnGitHub()}>
              {strings.t("github.openOnGitHub")}
            </button>
          </div>
        </div>
        {issue && (
          <div className="gh-meta">
            <StateBadge issue={issue} strings={strings} />
            {issue.user?.login && <span className="gh-author">{issue.user.login}</span>}
            {Number.isFinite(updatedAt) && (
              <span className="gh-muted">
                {strings.format("github.updated", relativeTime(updatedAt, now(), strings.language))}
              </span>
            )}
          </div>
        )}
        {issue && issue.labels.length > 0 && (
          <div className="gh-chips">
            <Labels labels={issue.labels} />
          </div>
        )}
        {snapshot.failure && issue && (
          <p className="gh-failure" role="alert">
            {snapshot.failure}
          </p>
        )}
      </header>
      {issue && (
        <div className="gh-body">
          <div className="gh-main">
            <section className="gh-section">
              <h2 className="gh-section-title">
                <span>{strings.t("github.description")}</span>
              </h2>
              {issue.body?.trim() ? (
                <GitHubMarkdown source={issue.body} open={open} />
              ) : (
                <p className="gh-muted">{strings.t("github.description.none")}</p>
              )}
            </section>
            <section className="gh-section">
              <h2 className="gh-section-title">
                <span>{strings.t("github.issue.comments")}</span>
                {issue.comments > 0 && <span className="gh-section-detail">{issue.comments}</span>}
              </h2>
              {comments.length === 0 ? (
                <p className="gh-muted">{strings.t("github.conversation.empty")}</p>
              ) : (
                <ol className="gh-timeline">
                  {comments.map((comment, index) => (
                    <Comment
                      key={comment.html_url || index}
                      comment={comment}
                      strings={strings}
                      now={now}
                      open={open}
                    />
                  ))}
                </ol>
              )}
              {issue.comments > comments.length && comments.length > 0 && (
                <button type="button" className="gh-more" onClick={() => store.openOnGitHub()}>
                  {strings.t("github.conversation.more")}
                </button>
              )}
            </section>
          </div>
        </div>
      )}
    </main>
  );
}

function IssueList({
  snapshot,
  store,
  strings,
  now,
}: {
  snapshot: ReturnType<IssuesStore["getSnapshot"]>;
  store: IssuesStore;
  strings: Strings;
  now: () => number;
}) {
  const { issues } = snapshot;
  if (!issues) {
    return snapshot.loading ? <p className="gh-muted gh-issues-note">{strings.t("github.issues.loading")}</p> : null;
  }
  if (issues.length === 0) return <p className="gh-muted gh-issues-note">{strings.t("github.issues.empty")}</p>;
  return (
    <ul className="gh-list gh-issue-list">
      {issues.map((issue) => {
        const updatedAt = Date.parse(issue.updated_at);
        return (
          <li key={issue.number} className="gh-issue-row" data-state={issue.state}>
            <IssueGlyph issue={issue} />
            <div className="gh-issue-main">
              <button type="button" className="gh-row-link gh-issue-title" onClick={() => store.openIssue(issue)}>
                {issue.title}
              </button>
              {issue.labels.length > 0 && (
                <span className="gh-issue-labels">
                  <Labels labels={issue.labels} />
                </span>
              )}
              <span className="gh-issue-meta gh-muted">
                #{issue.number}
                {issue.user?.login && (
                  <>
                    {" · "}
                    <span className="gh-issue-author">{issue.user.login}</span>
                  </>
                )}
                {Number.isFinite(updatedAt) && (
                  <> · {strings.format("github.updated", relativeTime(updatedAt, now(), strings.language))}</>
                )}
              </span>
            </div>
            {issue.comments > 0 && (
              <span className="gh-issue-comments gh-muted" aria-label={strings.t("github.issue.comments")}>
                <Icon name="bubble.left.and.text.bubble.right" size={12} />
                {issue.comments}
              </span>
            )}
          </li>
        );
      })}
    </ul>
  );
}

function Comment({
  comment,
  strings,
  now,
  open,
}: {
  comment: GitHubIssueComment;
  strings: Strings;
  now: () => number;
  open: (url: string) => void;
}) {
  const at = Date.parse(comment.created_at);
  return (
    <li className="gh-entry" data-kind="comment">
      <div className="gh-entry-head">
        {comment.user?.login && <span className="gh-author">{comment.user.login}</span>}
        <span className="gh-entry-verb">{strings.t("github.entry.commented")}</span>
        {Number.isFinite(at) && (
          <button type="button" className="gh-row-link gh-entry-time" onClick={() => open(comment.html_url)}>
            {relativeTime(at, now(), strings.language)}
          </button>
        )}
      </div>
      {comment.body?.trim() && <GitHubMarkdown source={comment.body} open={open} />}
    </li>
  );
}

function StateBadge({ issue, strings }: { issue: GitHubIssue; strings: Strings }) {
  const notPlanned = issue.state === "closed" && issue.state_reason === "not_planned";
  return (
    <span className="gh-badge" data-state={notPlanned ? "draft" : issue.state === "closed" ? "merged" : "open"}>
      {notPlanned
        ? strings.t("github.issue.notPlanned")
        : strings.t(issue.state === "closed" ? "github.state.closed" : "github.state.open")}
    </span>
  );
}

function Labels({ labels }: { labels: readonly GitHubIssueLabel[] }) {
  return (
    <>
      {labels.map((label) => (
        <span
          key={label.name}
          className="gh-label"
          data-colored={label.color ? true : undefined}
          style={label.color ? ({ "--gh-label": `#${label.color}` } as CSSProperties) : undefined}
        >
          {label.name}
        </span>
      ))}
    </>
  );
}

/** GitHub's issue glyph for its state: open green, closed (completed) purple, not planned grey. */
function IssueGlyph({ issue }: { issue?: GitHubIssue }) {
  const notPlanned = issue?.state === "closed" && issue.state_reason === "not_planned";
  const state = !issue ? undefined : notPlanned ? "draft" : issue.state === "closed" ? "merged" : "open";
  const name = notPlanned ? "git.issue.notplanned" : issue?.state === "closed" ? "git.issue.closed" : "git.issue";
  return (
    <span className="gh-glyph" data-state={state} aria-hidden="true">
      <Icon name={name} size={16} />
    </span>
  );
}
