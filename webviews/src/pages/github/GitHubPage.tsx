// The GitHub page (cmux-page://cmux.github/, Leo 2026-11-05: "can we potentially have, like, a
// better viewer than GitHub?"): one pull request, drawn from the app's cache with no github.com
// page load. The head says what it is and where it stands (state, author, branches, review, checks
// summary); the checks and the changed files follow, each file opening the diff viewer at it.
// Open on GitHub is always one click away.
import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { relativeTime } from "../../agent-session/acpmux/conversation/relativeTime";
import type { Strings } from "../shared/i18n";
import type { GitHubStore } from "./store";
import type { LinkedPullRequest } from "./types";

const STATES: Record<string, string> = {
  open: "github.state.open",
  draft: "github.state.draft",
  merged: "github.state.merged",
  closed: "github.state.closed",
};

const REVIEWS: Record<string, string> = {
  approved: "github.review.approved",
  changes_requested: "github.review.changesRequested",
  review_required: "github.review.required",
};

const CHECK_ORDER: Record<string, number> = { failed: 0, pending: 1, passed: 2 };

export function GitHubPage({
  store,
  strings,
  now = Date.now,
}: {
  store: GitHubStore;
  strings: Strings;
  now?: () => number;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const { t } = strings;
  const { target, pullRequest: pr } = snapshot;
  const hasContent = pr !== undefined;
  // Once the frame that draws this pull request (or its loading state) is on screen, the host hears of it.
  useEffect(() => {
    if (!target) return;
    let second = 0;
    const first = requestAnimationFrame(() => (second = requestAnimationFrame(() => store.shown())));
    return () => {
      cancelAnimationFrame(first);
      cancelAnimationFrame(second);
    };
  }, [store, target, hasContent]);
  if (!target) {
    return (
      <main className="gh">
        <p className="gh-muted">{t("github.noPullRequest")}</p>
      </main>
    );
  }
  const waitingFirst = !pr && (!snapshot.answered || snapshot.reading);
  const updatedAt = pr?.updatedAt ? Date.parse(pr.updatedAt) : Number.NaN;
  return (
    <main className="gh" aria-busy={waitingFirst}>
      <header className="gh-head">
        <div className="gh-ref">
          <PullGlyph state={pr?.state} />
          <span>
            {target.repo} #{target.number}
          </span>
        </div>
        <h1 className="gh-title">{pr?.title || (waitingFirst ? t("github.loading") : t("github.unavailable"))}</h1>
        {pr && (
          <div className="gh-meta">
            {STATES[pr.state] && (
              <span className="gh-badge" data-state={pr.state}>
                {t(STATES[pr.state]!)}
              </span>
            )}
            {pr.author && <span className="gh-author">{pr.author}</span>}
            {pr.baseRef && pr.headRef && (
              <span className="gh-branches">
                <code>{pr.baseRef}</code> ← <code>{pr.headRef}</code>
              </span>
            )}
            {Number.isFinite(updatedAt) && (
              <span className="gh-muted">
                {strings.format("github.updated", relativeTime(updatedAt, now(), strings.language))}
              </span>
            )}
          </div>
        )}
        <div className="gh-actions">
          <button
            type="button"
            className="gh-button gh-button--primary"
            disabled={!pr}
            onClick={() => void store.openDiff()}
          >
            {t("github.viewDiff")}
          </button>
          <button type="button" className="gh-button" onClick={() => store.openOnGitHub()}>
            {t("github.openOnGitHub")}
          </button>
        </div>
        {snapshot.failure && (
          <p className="gh-failure" role="alert">
            {snapshot.failure}
          </p>
        )}
      </header>
      {pr && <Review pr={pr} strings={strings} />}
      {pr && <Checks pr={pr} strings={strings} open={(url) => store.openOnGitHub(url)} />}
      {pr && (
        <Files
          pr={pr}
          strings={strings}
          open={(file) => void store.openDiff(file)}
          more={() => store.openOnGitHub(`${target.url}/files`)}
        />
      )}
    </main>
  );
}

function Review({ pr, strings }: { pr: LinkedPullRequest; strings: Strings }) {
  const review = REVIEWS[pr.review];
  const conflicts = pr.mergeable === "conflicting";
  if (!review && !conflicts && pr.comments == null) return null;
  return (
    <section className="gh-section gh-review">
      {review && (
        <span className="gh-review-state" data-review={pr.review}>
          {strings.t(review)}
        </span>
      )}
      {conflicts && <span className="gh-conflicts">{strings.t("github.conflicts")}</span>}
      {pr.comments != null && (
        <span className="gh-muted">
          {strings.t("github.comments")} <span className="gh-count">{pr.comments}</span>
        </span>
      )}
    </section>
  );
}

function Checks({ pr, strings, open }: { pr: LinkedPullRequest; strings: Strings; open: (url: string) => void }) {
  const list = [...(pr.checkList ?? [])].sort((a, b) => (CHECK_ORDER[a.state] ?? 3) - (CHECK_ORDER[b.state] ?? 3));
  return (
    <Section
      title={strings.t("github.checks")}
      detail={pr.checks.total ? `${pr.checks.passed}/${pr.checks.total}` : undefined}
    >
      {list.length === 0 ? (
        <p className="gh-muted">{strings.t("github.checks.none")}</p>
      ) : (
        <ul className="gh-list">
          {list.map((check) => (
            <li key={check.name} className="gh-row" data-check={check.state}>
              <span className="gh-dot" aria-hidden="true" />
              {check.url ? (
                <button type="button" className="gh-row-link" onClick={() => open(check.url!)}>
                  {check.name}
                </button>
              ) : (
                <span className="gh-row-name">{check.name}</span>
              )}
              {check.onBase && <span className="gh-muted">{strings.t("github.checks.onBase")}</span>}
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

function Files({
  pr,
  strings,
  open,
  more,
}: {
  pr: LinkedPullRequest;
  strings: Strings;
  open: (file: string) => void;
  more: () => void;
}) {
  const files = pr.files ?? [];
  const total = Math.max(pr.changedFiles ?? 0, files.length);
  return (
    <Section
      title={strings.t("github.files")}
      detail={
        pr.additions != null && pr.deletions != null ? <Lines add={pr.additions} del={pr.deletions} /> : undefined
      }
    >
      <ul className="gh-list">
        {files.map((file) => (
          <li key={file.path} className="gh-row">
            <button type="button" className="gh-row-link gh-path" title={file.path} onClick={() => open(file.path)}>
              {file.path}
            </button>
            <Lines add={file.additions} del={file.deletions} />
          </li>
        ))}
      </ul>
      {total > files.length && (
        <button type="button" className="gh-more" onClick={more}>
          {strings.t("github.files.more")}
        </button>
      )}
    </Section>
  );
}

function Section({ title, detail, children }: { title: string; detail?: ReactNode; children: ReactNode }) {
  return (
    <section className="gh-section">
      <h2 className="gh-section-title">
        <span>{title}</span>
        {detail != null && <span className="gh-section-detail">{detail}</span>}
      </h2>
      {children}
    </section>
  );
}

function Lines({ add, del }: { add: number; del: number }) {
  return (
    <span className="gh-lines">
      <span className="gh-add">+{add}</span> <span className="gh-del">−{del}</span>
    </span>
  );
}

/** GitHub's pull request glyph in its state's colour (open green, merged purple, closed red, draft grey). */
function PullGlyph({ state }: { state?: string }) {
  return (
    <svg
      className="gh-glyph"
      data-state={state || undefined}
      width="16"
      height="16"
      viewBox="0 0 16 16"
      aria-hidden="true"
    >
      <path
        fill="currentColor"
        d="M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
      />
    </svg>
  );
}
