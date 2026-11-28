// The GitHub page (cmux-page://cmux.github/, Leo, 2026-11-05: "can we potentially have, like, a
// better viewer than GitHub?"): one pull request, drawn from the app's cache with no github.com
// page load. Leo, 2026-11-07, asked for the rest of the page: the description and the comments
// themselves near the top, wider, checks condensed to their reds, files that expand inline, a
// View all changes button and Merge, and asked how the hierarchy should go if drawn from scratch.
//
// The answer here (design/github-page.md): a header that says what it is and where it stands
// (title, state, author, branches, labels, diff totals, a checks tally) with the actions beside
// it; then, on a wide pane, two columns. The main column is what a person reads: the description,
// the files changed (wide enough for an inline diff), then the conversation in time order. The
// rail is what a person checks: checks with reds and running first and greens folded, reviewers,
// linked issues. A narrow pane is one column in that order.
import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useState,
  type CSSProperties,
  type ReactNode,
  useId,
  memo,
  useMemo,
} from "react";
import { relativeTime } from "../../agent-session/acpmux/conversation/relativeTime";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
// Imported, not `new URL(...)`: the page's CSP allows `img-src data:` only, and bundle.mjs inlines it.
import mascotMoon from "../../agent-session/acpmux/mascots/ChiefMascotMoon.png";
import { IllustratedEmpty } from "../../ui/EmptyState/IllustratedEmpty";
import type { Strings } from "../shared/i18n";
import { ChecksDashboard } from "./ChecksDashboard";
import { withRollup } from "./checksModel";
import {
  filterConversation,
  filterCounts,
  type ConversationFilter,
  type ConversationOrder,
} from "./conversationFilter";
import { GitHubMarkdown } from "./GitHubMarkdown";
import { ReadinessBlock, type ReadinessLayout } from "./ReadinessBlock";
import { ReviewBox, ThreadActions } from "./ReviewBox";
import type { Blocker } from "./readiness";
import type { GitHubStore } from "./store";
import { useGitHubSlice } from "./useGitHubSlice";
import type { ConversationEntry, FilePatch, LinkedPullRequest, PullRequestDetails } from "./types";

/** The empty page's button: the person's open pull requests on GitHub, in a cmux tab. */
const PULLS_URL = "https://github.com/pulls";

/// Pierre comes in its own chunk, loaded when a file first opens.
const GitHubFileDiff = lazy(() => import("./GitHubFileDiff").then((module) => ({ default: module.GitHubFileDiff })));

/**
 * Where the sections go. `split` (shipped): files in the main column, beside the conversation,
 * where an inline diff has room; the rail holds checks, reviewers and linked issues. `rail`: the
 * files in the rail too. `single`: one column at every width.
 */
export type GitHubLayout = "split" | "rail" | "single";

/**
 * Where the checks go. `top` (shipped): the CI dashboard across the page's whole width under the
 * header, where a long matrix and a log excerpt have room (Leo, 2026-11-07: "here's your big
 * dashboard"). `rail`: in the rail, as before.
 */
export type ChecksPlacement = "top" | "rail";

/**
 * How much of the pane the page takes. `fill` (shipped): the whole pane less a gutter, so the
 * description, its tables and the checks use the room (Leo, 2026-11-07: "it's just giving up way
 * too much space"). `wide`: 94% of the pane up to 2200px. `column`: 84% up to 1560px, as before.
 */
export type PageWidth = "fill" | "wide" | "column";

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

const VERBS: Record<string, string> = {
  approved: "github.entry.approved",
  changes_requested: "github.entry.changesRequested",
  commented: "github.entry.reviewed",
  dismissed: "github.entry.dismissed",
};

const REVIEWER_STATES: Record<string, string> = {
  approved: "github.review.approved",
  changes_requested: "github.review.changesRequested",
  requested: "github.reviewers.requested",
  commented: "github.entry.reviewed",
  dismissed: "github.entry.dismissed",
};

const MERGE_METHODS: Record<string, string> = {
  merge: "github.merge.merge",
  squash: "github.merge.squash",
  rebase: "github.merge.rebase",
};

/** GitHub's merge states that say the pull request cannot merge now. */
const UNMERGEABLE = new Set(["blocked", "behind", "dirty", "draft"]);

type Check = LinkedPullRequest["checkList"][number];

/** The checks by outcome: failing, then running, then passed. */
export function groupChecks(list: readonly Check[]) {
  const failed = list.filter((check) => check.state === "failed");
  const pending = list.filter((check) => check.state === "pending");
  const passed = list.filter((check) => check.state !== "failed" && check.state !== "pending");
  return { failed, pending, passed };
}

/** A file's five cells: added, removed, then unchanged (a small change fills fewer). */
export function fileCells(add: number, del: number): ("add" | "del" | "none")[] {
  const total = add + del;
  const filled = Math.min(5, total);
  const adds = total ? Math.round((filled * add) / total) : 0;
  return Array.from({ length: 5 }, (_, at) => (at < adds ? "add" : at < filled ? "del" : "none"));
}

export function GitHubPage({
  store,
  strings,
  now = Date.now,
  layout = "split",
  checksPlacement = "top",
  width = "fill",
  readinessLayout = "list",
  readinessShown,
  conversationFilter = "all",
  reviewDraft,
  replyOpen,
  onIssues,
}: {
  store: GitHubStore;
  strings: Strings;
  now?: () => number;
  /** Opens the repository's issues in this page (its Issues button); no button without it. */
  onIssues?: (repo: string) => void;
  layout?: GitHubLayout;
  checksPlacement?: ChecksPlacement;
  width?: PageWidth;
  /** How the merge readiness block lays out its blockers (the gallery's candidates). */
  readinessLayout?: ReadinessLayout;
  /** The blocker whose detail starts open, and the conversation's first filter (gallery states). */
  readinessShown?: Blocker["kind"];
  conversationFilter?: ConversationFilter;
  /** The review box's starting words, and the thread whose reply box starts open (gallery states). */
  reviewDraft?: string;
  replyOpen?: string;
}) {
  // Each part reads its own slice (useGitHubSlice.ts): a patch, a write or a merge step draws only its part.
  const target = useGitHubSlice(store, (s) => s.target);
  const pr = useGitHubSlice(store, (s) => s.pullRequest);
  const details = useGitHubSlice(store, (s) => s.details);
  const answered = useGitHubSlice(store, (s) => s.answered);
  const reading = useGitHubSlice(store, (s) => s.reading);
  const dashboard = useGitHubSlice(store, (s) => s.checks);
  const rerun = useGitHubSlice(store, (s) => s.rerun);
  const { t } = strings;
  const hasContent = pr !== undefined;
  // One callback for the page's life: GitHubMarkdown parses a body again only when its text changes.
  const open = useCallback((url: string) => store.openOnGitHub(url), [store]);
  const more = useCallback(() => store.openOnGitHub(), [store]);
  // Once per answer: a file toggled or a merge clicked keeps the dashboard's jobs as they were.
  const rollup = pr?.checkList;
  const checksShown = useMemo(
    () => (dashboard ? withRollup(dashboard, rollup ?? []) : null),
    [dashboard, rollup],
  );
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
        <IllustratedEmpty
          className="gh-empty"
          art={mascotMoon}
          line={t("github.noPullRequest")}
          action={{ label: t("github.empty.openPullRequests"), onClick: () => store.openOnGitHub(PULLS_URL) }}
        />
      </main>
    );
  }
  const waitingFirst = !pr && (!answered || reading);
  const description = pr && <Description details={details} strings={strings} open={open} />;
  const files = pr && <Files pr={pr} store={store} strings={strings} />;
  const conversation = pr && (
    <Conversation
      details={details}
      prState={pr.state}
      store={store}
      reviewDraft={reviewDraft}
      replyOpen={replyOpen}
      strings={strings}
      now={now}
      open={open}
      more={more}
      initialFilter={conversationFilter}
    />
  );
  // The dashboard once the host has the jobs; until then the cache's rollup, in the same place.
  const checks =
    pr &&
    (checksShown ? (
      <ChecksDashboard
        checks={checksShown}
        rerun={rerun}
        store={store}
        strings={strings}
        now={now}
        open={open}
      />
    ) : (
      <Checks pr={pr} strings={strings} open={open} />
    ));
  const reviewers = details && details.reviewers.length > 0 && <Reviewers details={details} strings={strings} />;
  const linked = details && details.linked.length > 0 && <Linked details={details} strings={strings} open={open} />;
  return (
    <main className="gh" data-layout={layout} data-width={width} aria-busy={waitingFirst}>
      <Header
        target={target}
        pr={pr}
        details={details}
        store={store}
        strings={strings}
        now={now}
        waitingFirst={waitingFirst}
        onIssues={onIssues}
      />
      {pr && (
        <ReadinessBlock
          pr={pr}
          details={details}
          checks={checksShown}
          strings={strings}
          open={open}
          layout={readinessLayout}
          shownFirst={readinessShown}
        />
      )}
      {pr && checksPlacement === "top" && <div className="gh-ci-band">{checks}</div>}
      {pr && (
        <div className="gh-body">
          <div className="gh-main">
            {description}
            {layout !== "rail" && files}
            {conversation}
          </div>
          <aside className="gh-rail">
            {checksPlacement === "rail" && checks}
            {layout === "rail" && files}
            {reviewers}
            {linked}
          </aside>
        </div>
      )}
    </main>
  );
}

function Header({
  target,
  pr,
  details,
  store,
  strings,
  now,
  waitingFirst,
  onIssues,
}: {
  target: { url: string; repo: string; number: number };
  pr?: LinkedPullRequest;
  details?: PullRequestDetails;
  store: GitHubStore;
  strings: Strings;
  now: () => number;
  waitingFirst: boolean;
  onIssues?: (repo: string) => void;
}) {
  const { t } = strings;
  const failure = useGitHubSlice(store, (s) => s.failure);
  const updatedAt = pr?.updatedAt ? Date.parse(pr.updatedAt) : Number.NaN;
  const labels: { name: string; color: string }[] =
    details?.labels ?? (pr?.labels ?? []).map((name) => ({ name, color: "" }));
  return (
    <header className="gh-head">
      <div className="gh-ref">
        <PullGlyph state={pr?.state} />
        <span>
          {target!.repo} #{target!.number}
        </span>
        {details?.headCommit && <code className="gh-sha">{details.headCommit.slice(0, 7)}</code>}
      </div>
      <div className="gh-head-row">
        <h1 className="gh-title">{pr?.title || (waitingFirst ? t("github.loading") : t("github.unavailable"))}</h1>
        <div className="gh-actions">
          {pr && <MergeButton pr={pr} details={details} store={store} strings={strings} />}
          <button type="button" className="gh-button" disabled={!pr} onClick={() => void store.openDiff()}>
            {t("github.viewAllChanges")}
          </button>
          {onIssues && (
            <button type="button" className="gh-button" onClick={() => onIssues(target!.repo)}>
              {t("github.issues")}
            </button>
          )}
          <button type="button" className="gh-button" onClick={() => store.openOnGitHub()}>
            {t("github.openOnGitHub")}
          </button>
        </div>
      </div>
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
      {pr && (
        <div className="gh-chips">
          {pr.additions != null && pr.deletions != null && (
            <span className="gh-chip gh-chip--plain">
              <Lines add={pr.additions} del={pr.deletions} />
              <span className="gh-muted">
                {t("github.files")} {Math.max(pr.changedFiles ?? 0, pr.files?.length ?? 0)}
              </span>
            </span>
          )}
          {pr.checks.total > 0 && <CheckTally pr={pr} strings={strings} />}
          {REVIEWS[pr.review] && (
            <span className="gh-chip gh-review-state" data-review={pr.review}>
              {t(REVIEWS[pr.review]!)}
            </span>
          )}
          {pr.mergeable === "conflicting" && <span className="gh-chip gh-conflicts">{t("github.conflicts")}</span>}
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
        </div>
      )}
      {failure && (
        <p className="gh-failure" role="alert">
          {failure}
        </p>
      )}
    </header>
  );
}

/** Merge through GitHub's normal path: a first click names the method, the second merges the shown head. */
function MergeButton({
  pr,
  details,
  store,
  strings,
}: {
  pr?: LinkedPullRequest;
  details?: PullRequestDetails;
  store: GitHubStore;
  strings: Strings;
}) {
  const { t } = strings;
  const why = useId();
  const merge = useGitHubSlice(store, (s) => s.merge);
  if (!pr || pr.state !== "open") return null;
  if (merge.phase === "merged") {
    return (
      <span className="gh-merge-done" aria-live="polite">
        {t(merge.queued ? "github.merge.queued" : "github.merge.merged")}
      </span>
    );
  }
  const ready = details !== undefined && details.headCommit !== "" && !UNMERGEABLE.has(details.mergeState);
  if (merge.phase === "confirm" || merge.phase === "merging") {
    return (
      <span className="gh-merge-confirm">
        <button
          type="button"
          className="gh-button gh-button--primary"
          disabled={merge.phase === "merging"}
          aria-describedby={why}
          onClick={() => void store.merge()}
        >
          {merge.phase === "merging"
            ? t("github.merge.merging")
            : t(MERGE_METHODS[details?.mergeMethod ?? "merge"] ?? "github.merge.merge")}
        </button>
        <button
          type="button"
          className="gh-button"
          disabled={merge.phase === "merging"}
          onClick={() => store.cancelMerge()}
        >
          {t("github.merge.cancel")}
        </button>
        {/* Which commit it merges, as text (Chief, 2026-11-21: what a tooltip said shows on the page). */}
        <span className="gh-merge-note gh-merge-pinned" id={why}>
          {strings.format("github.merge.pinned", details?.headCommit.slice(0, 7) ?? "")}
        </span>
      </span>
    );
  }
  return (
    <>
      <button
        type="button"
        className="gh-button gh-button--primary"
        disabled={!ready}
        aria-describedby={details && !ready ? why : undefined}
        onClick={() => void store.merge()}
      >
        {t("github.merge")}
      </button>
      {/* Why it cannot merge yet, as text: a disabled button gets no hover. A refused merge says it below. */}
      {details && !ready && merge.phase !== "failed" && (
        <span className="gh-merge-note gh-merge-why" id={why}>
          {t("github.merge.notReady")}
        </span>
      )}
      {merge.phase === "failed" && merge.message && (
        <span className="gh-failure gh-merge-failure" role="alert">
          {merge.refused ? t("github.merge.notReady") : merge.message}
        </span>
      )}
    </>
  );
}

/** The checks' tally: a dot and a count per outcome that has any. */
function CheckTally({ pr, strings }: { pr: LinkedPullRequest; strings: Strings }) {
  const { failed, pending, passed } = groupChecks(pr.checkList ?? []);
  const rows: [string, number, string][] = [
    ["failed", failed.length, "github.checks.failing"],
    ["pending", pending.length, "github.checks.running"],
    ["passed", passed.length, "github.checks.passed"],
  ];
  return (
    <span className="gh-chip gh-chip--plain gh-tally">
      {rows
        .filter(([, count]) => count > 0)
        .map(([state, count, label]) => (
          <span key={state} className="gh-tally-item" data-check={state}>
            <span className="gh-dot" aria-hidden="true" />
            {/* The outcome in words, not only the dot's colour (Chief, 2026-11-21). */}
            <span className="gh-count">{count}</span> <span className="gh-tally-word">{strings.t(label)}</span>
          </span>
        ))}
    </span>
  );
}

function Description({
  details,
  strings,
  open,
}: {
  details?: PullRequestDetails;
  strings: Strings;
  open: (url: string) => void;
}) {
  return (
    <Section title={strings.t("github.description")}>
      {!details ? (
        <p className="gh-muted">{strings.t("github.description.loading")}</p>
      ) : details.body.trim() ? (
        <GitHubMarkdown source={details.body} html={details.html} open={open} />
      ) : (
        <p className="gh-muted">{strings.t("github.description.none")}</p>
      )}
    </Section>
  );
}

/** The conversation: at most GitHubPullRequestDetails.maximumComments (50) comments and
 *  maximumReviews (30) reviews, so every entry is drawn; each is a memoized Entry, and the whole
 *  section draws again only when its details, filter or order change (not on a file's toggle). */
const Conversation = memo(function Conversation({
  details,
  prState,
  store,
  reviewDraft,
  replyOpen,
  strings,
  now,
  open,
  more,
  initialFilter,
}: {
  details?: PullRequestDetails;
  prState: string;
  store: GitHubStore;
  reviewDraft?: string;
  replyOpen?: string;
  strings: Strings;
  now: () => number;
  open: (url: string) => void;
  more: () => void;
  initialFilter: ConversationFilter;
}) {
  const [filter, setFilter] = useState<ConversationFilter>(initialFilter);
  const [order, setOrder] = useState<ConversationOrder>("newest");
  const conversation = details?.conversation;
  const viewer = details?.viewer;
  const counts = useMemo(() => filterCounts(conversation ?? [], viewer), [conversation, viewer]);
  const entries = useMemo(
    () => filterConversation(conversation ?? [], filter, order, viewer),
    [conversation, filter, order, viewer],
  );
  if (!details) return null;
  const { t } = strings;
  const filters: [ConversationFilter, string][] = [
    ["all", "github.conversation.all"],
    ["unresolved", "github.conversation.unresolved"],
  ];
  if (details.viewer) filters.push(["mine", "github.conversation.mine"]);
  return (
    <Section
      title={t("github.conversation")}
      detail={details.conversationTotal ? String(details.conversationTotal) : undefined}
    >
      {details.conversation.length > 0 && (
        <div className="gh-conversation-bar">
          <fieldset className="gh-segments" aria-label={t("github.conversation.filter")}>
            {filters.map(([value, key]) => (
              <button
                key={value}
                type="button"
                className="gh-segment"
                aria-pressed={filter === value}
                onClick={() => setFilter(value)}
              >
                {t(key)} <span className="gh-segment-count">{counts[value]}</span>
              </button>
            ))}
          </fieldset>
          <button
            type="button"
            className="gh-fold gh-conversation-order"
            onClick={() => setOrder(order === "newest" ? "oldest" : "newest")}
          >
            {t(order === "newest" ? "github.conversation.newest" : "github.conversation.oldest")}
          </button>
        </div>
      )}
      {/* Counted as the host counts the total (review of #38263, F1): an empty review wrapper the
          host left out is not a comment GitHub has that the page lacks. */}
      {details.conversationTotal > details.conversationRead && (
        <button type="button" className="gh-more" onClick={more}>
          {t("github.conversation.more")}
        </button>
      )}
      {entries.length === 0 ? (
        <p className="gh-muted">
          {t(details.conversation.length ? "github.conversation.none" : "github.conversation.empty")}
        </p>
      ) : (
        <ol className="gh-timeline">
          {entries.map((entry, index) => (
            <Entry
              key={entry.url ?? index}
              entry={entry}
              prState={prState}
              store={store}
              replyOpen={replyOpen}
              strings={strings}
              now={now}
              open={open}
            />
          ))}
        </ol>
      )}
      <ReviewBox prState={prState} store={store} strings={strings} initialBody={reviewDraft} />
    </Section>
  );
});

/** One comment or review; drawn again only when its entry changes (the store keeps unchanged ones).
 *  It takes the pull request's state, never the snapshot, which is new on every
 *  change to the page (a file's toggle, a re-read) and would draw every entry again. */
const Entry = memo(function Entry({
  entry,
  prState,
  store,
  replyOpen,
  strings,
  now,
  open,
}: {
  entry: ConversationEntry;
  prState: string;
  store: GitHubStore;
  replyOpen?: string;
  strings: Strings;
  now: () => number;
  open: (url: string) => void;
}) {
  const at = Date.parse(entry.at);
  const verb = entry.kind === "review" ? VERBS[entry.state ?? "commented"] : "github.entry.commented";
  return (
    <li className="gh-entry" data-kind={entry.kind} data-state={entry.state ?? undefined}>
      <div className="gh-entry-head">
        <span className="gh-author">{entry.author}</span>
        <span className="gh-entry-verb">{strings.t(verb ?? "github.entry.reviewed")}</span>
        {Number.isFinite(at) &&
          (entry.url ? (
            <button type="button" className="gh-row-link gh-entry-time" onClick={() => open(entry.url!)}>
              {relativeTime(at, now(), strings.language)}
            </button>
          ) : (
            <span className="gh-entry-time">{relativeTime(at, now(), strings.language)}</span>
          ))}
      </div>
      {entry.body.trim() && <GitHubMarkdown source={entry.body} html={entry.html} open={open} />}
      {entry.comments.length > 0 && (
        <ul className="gh-review-comments">
          {entry.comments.map((comment, index) => (
            <li key={comment.url ?? index} className="gh-review-comment">
              <span className="gh-path gh-review-comment-path">
                {comment.path}
                {comment.line != null && `:${comment.line}`}
              </span>
              <GitHubMarkdown source={comment.body} html={comment.html} open={open} />
              {comment.thread && prState === "open" && (
                <ThreadActions
                  thread={comment.thread}
                  resolved={comment.resolved === true}
                  store={store}
                  strings={strings}
                  initialReplying={replyOpen === comment.thread}
                />
              )}
            </li>
          ))}
        </ul>
      )}
    </li>
  );
});

function Checks({ pr, strings, open }: { pr: LinkedPullRequest; strings: Strings; open: (url: string) => void }) {
  const [showPassed, setShowPassed] = useState(false);
  const list = pr.checkList ?? [];
  const { failed, pending, passed } = groupChecks(list);
  const total = list.length;
  const row = (check: Check) => <CheckRow key={check.name} check={check} strings={strings} open={open} />;
  return (
    <Section title={strings.t("github.checks")} detail={total ? `${passed.length}/${total}` : undefined}>
      {total === 0 ? (
        <p className="gh-muted">{strings.t("github.checks.none")}</p>
      ) : (
        <>
          {/* One bar, each outcome's share of it: red, then yellow, then green. */}
          <div className="gh-check-bar" aria-hidden="true">
            {failed.length > 0 && <span data-check="failed" style={{ flexGrow: failed.length }} />}
            {pending.length > 0 && <span data-check="pending" style={{ flexGrow: pending.length }} />}
            {passed.length > 0 && <span data-check="passed" style={{ flexGrow: passed.length }} />}
          </div>
          {failed.length > 0 && (
            <CheckGroup label={strings.t("github.checks.failing")} count={failed.length} state="failed">
              {failed.map(row)}
            </CheckGroup>
          )}
          {pending.length > 0 && (
            <CheckGroup label={strings.t("github.checks.running")} count={pending.length} state="pending">
              {pending.map(row)}
            </CheckGroup>
          )}
          {passed.length > 0 && (
            <div className="gh-check-group" data-check="passed">
              <button
                type="button"
                className="gh-fold"
                aria-expanded={showPassed}
                onClick={() => setShowPassed((shown) => !shown)}
              >
                <Chevron open={showPassed} />
                <span className="gh-dot" aria-hidden="true" />
                <span>{strings.t("github.checks.passed")}</span>
                <span className="gh-count">{passed.length}</span>
              </button>
              {showPassed && <ul className="gh-list">{passed.map(row)}</ul>}
            </div>
          )}
        </>
      )}
    </Section>
  );
}

/** One check of the rollup, which reads at most 100 (AgentChatPullRequestReader `contexts(first: 100)`),
 *  so every one is drawn; memoized, so the page's other changes do not draw it again. */
const CheckRow = memo(function CheckRow({
  check,
  strings,
  open,
}: {
  check: Check;
  strings: Strings;
  open: (url: string) => void;
}) {
  return (
    <li className="gh-row" data-check={check.state}>
      <span className="gh-dot" aria-hidden="true" />
      {check.url ? (
        <button type="button" className="gh-row-link" onClick={() => open(check.url!)}>
          {check.name}
        </button>
      ) : (
        <span className="gh-row-name">{check.name}</span>
      )}
      {check.onBase && <span className="gh-muted gh-row-note">{strings.t("github.checks.onBase")}</span>}
    </li>
  );
});

function CheckGroup({
  label,
  count,
  state,
  children,
}: {
  label: string;
  count: number;
  state: string;
  children: ReactNode;
}) {
  return (
    <div className="gh-check-group" data-check={state}>
      <div className="gh-check-group-title">
        <span>{label}</span>
        <span className="gh-count">{count}</span>
      </div>
      <ul className="gh-list">{children}</ul>
    </div>
  );
}

function Files({ pr, store, strings }: { pr: LinkedPullRequest; store: GitHubStore; strings: Strings }) {
  const patches = useGitHubSlice(store, (s) => s.patches);
  const files = pr.files ?? [];
  const total = Math.max(pr.changedFiles ?? 0, files.length);
  // One column width for every row's counts, so the +/− line up down the list.
  const digits = files.reduce(
    (most, file) => Math.max(most, String(file.additions).length, String(file.deletions).length),
    1,
  );
  return (
    <Section
      title={strings.t("github.files")}
      detail={
        pr.additions != null && pr.deletions != null ? <Lines add={pr.additions} del={pr.deletions} /> : undefined
      }
    >
      <ul className="gh-files" style={{ "--gh-digits": `${digits + 1}ch` } as CSSProperties}>
        {files.map((file) => (
          <FileRow key={file.path} file={file} patch={patches[file.path]} store={store} strings={strings} />
        ))}
      </ul>
      {total > files.length && (
        <button type="button" className="gh-more" onClick={() => store.openOnGitHub(`${pr.url}/files`)}>
          {strings.t("github.files.more")}
        </button>
      )}
    </Section>
  );
}

type PullRequestFile = NonNullable<LinkedPullRequest["files"]>[number];

/** One changed file and, expanded, its diff. The pull request's read takes at most 100 files
 *  (AgentChatPullRequestReader `files(first: 100)`; more open on GitHub), so every one is drawn;
 *  memoized, so expanding one file draws only that one again. */
const FileRow = memo(function FileRow({
  file,
  patch,
  store,
  strings,
}: {
  file: PullRequestFile;
  patch: FilePatch | undefined;
  store: GitHubStore;
  strings: Strings;
}) {
  return (
    <li className="gh-file" data-open={patch ? true : undefined}>
      <button
        type="button"
        className="gh-file-row"
        aria-expanded={patch !== undefined}
        onClick={() => store.toggleFile(file.path)}
      >
        <Chevron open={patch !== undefined} />
        <span className="gh-path gh-file-path">
          <FilePath path={file.path} />
        </span>
        <span className="gh-num gh-add">+{file.additions}</span>
        <span className="gh-num gh-del">−{file.deletions}</span>
        <span className="gh-cells" aria-hidden="true">
          {fileCells(file.additions, file.deletions).map((cell, at) => (
            <span key={at} data-cell={cell} />
          ))}
        </span>
      </button>
      {patch && <FileBody patch={patch} strings={strings} open={() => void store.openDiff(file.path)} />}
    </li>
  );
});

function FileBody({ patch, strings, open }: { patch: FilePatch; strings: Strings; open: () => void }) {
  const note =
    patch.state === "loading"
      ? strings.t("github.files.loading")
      : patch.state === "tooLarge"
        ? strings.t("github.files.tooLarge")
        : patch.state === "missing"
          ? strings.t("github.files.missing")
          : patch.state === "failed"
            ? patch.message || strings.t("github.files.failed")
            : undefined;
  return (
    <div className="gh-file-body">
      {patch.state === "ready" ? (
        <div className="gh-file-diff">
          <Suspense fallback={<p className="gh-muted gh-file-note">{strings.t("github.files.loading")}</p>}>
            <GitHubFileDiff patch={patch.patch} />
          </Suspense>
        </div>
      ) : (
        <p className="gh-muted gh-file-note">{note}</p>
      )}
      <div className="gh-file-actions">
        <button type="button" className="gh-more" onClick={open}>
          {strings.t("github.files.openInViewer")}
        </button>
      </div>
    </div>
  );
}

/** A path with its folder dimmed, so the file's name reads first. */
function FilePath({ path }: { path: string }) {
  const cut = path.lastIndexOf("/") + 1;
  return (
    <>
      {cut > 0 && <span className="gh-file-folder">{path.slice(0, cut)}</span>}
      {path.slice(cut)}
    </>
  );
}

function Reviewers({ details, strings }: { details: PullRequestDetails; strings: Strings }) {
  return (
    <Section title={strings.t("github.reviewers")}>
      <ul className="gh-list">
        {details.reviewers.map((reviewer) => (
          <li key={reviewer.name} className="gh-row" data-review={reviewer.state}>
            <span className="gh-row-name">{reviewer.name}</span>
            <span className="gh-reviewer-state">
              {strings.t(REVIEWER_STATES[reviewer.state] ?? "github.entry.reviewed")}
            </span>
          </li>
        ))}
      </ul>
    </Section>
  );
}

function Linked({
  details,
  strings,
  open,
}: {
  details: PullRequestDetails;
  strings: Strings;
  open: (url: string) => void;
}) {
  return (
    <Section title={strings.t("github.linked")}>
      <ul className="gh-list">
        {details.linked.map((item) => (
          <li key={item.url} className="gh-row" data-issue={item.state}>
            <span className="gh-dot" aria-hidden="true" />
            <button type="button" className="gh-row-link" onClick={() => open(item.url)}>
              <span className="gh-count">#{item.number}</span> {item.title}
            </button>
          </li>
        ))}
      </ul>
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

function Chevron({ open }: { open: boolean }) {
  return (
    <span className="gh-chevron" data-open={open || undefined} aria-hidden="true">
      <Icon name="disclosure.collapsed" size={12} />
    </span>
  );
}

/** The pack's pull request glyph for each state, as the chat's hover card and header chip draw it. */
const PULL_GLYPHS: Record<string, string> = {
  merged: "git.pullrequest.merged",
  closed: "git.pullrequest.closed",
  draft: "git.pullrequest.draft",
};

/** The pull request glyph in its state's colour (open green, merged purple, closed red, draft grey). */
function PullGlyph({ state }: { state?: string }) {
  return (
    <span className="gh-glyph" data-state={state || undefined} aria-hidden="true">
      <Icon name={(state && PULL_GLYPHS[state]) || "git.pullrequest"} size={16} />
    </span>
  );
}
