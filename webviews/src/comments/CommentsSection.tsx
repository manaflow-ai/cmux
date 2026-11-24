import { commentDisplayName } from "./format";
import type { SidebarCommentEntry } from "./annotations";
import { fillCommentLabel, type DiffCommentLabels } from "./labels";
import type { CommentsPostState, CommentsSendState, DiffReviewPosted, DiffReviewTarget } from "./types";

/** A review worktree's part of the section: its pull request, its last post and the Post action. */
export type CommentsReview = {
  review: DiffReviewTarget;
  onPost: () => void;
  postState: CommentsPostState;
  posted?: DiffReviewPosted;
  postError?: string;
};

/**
 * The sidebar's saved comments. With a host that sends to the diff's chat (`onSend`), the header's
 * trailing button sends them all as one prompt; it keeps its width while sending, so nothing in
 * the header moves, and a refusal shows under the header with the comments still listed.
 *
 * A review worktree's (`review` with `onPost`) are drafts for a GitHub pull request: the header's
 * button posts them as one review, and one line under it names the pull request (then the posted
 * review) with Send to agent as its quiet end, so asking the agent about a draft stays one click.
 * That line is there in every post state, so the header never changes height.
 */
export function CommentsSidebarSection({
  entries,
  hasDraft,
  labels,
  onPost,
  onSelect,
  onSend,
  postError,
  postState = "idle",
  posted,
  review,
  sendState = "idle",
}: {
  entries: SidebarCommentEntry[];
  hasDraft: boolean;
  labels: DiffCommentLabels;
  /** Posts every saved comment to `review`'s pull request; absent when the host cannot. */
  onPost?: () => void;
  onSelect: (entry: SidebarCommentEntry) => void;
  onSend?: () => void;
  /** gh's reason for the last refused post. */
  postError?: string;
  postState?: CommentsPostState;
  posted?: DiffReviewPosted;
  review?: DiffReviewTarget;
  sendState?: CommentsSendState;
}) {
  const reviewing = review != null && onPost != null;
  // A review worktree keeps its section with no drafts: it says which pull request, and what posted.
  if (entries.length === 0 && !hasDraft && !reviewing) {
    return null;
  }
  const send = onSend ? (
    <TwoLabelButton
      id="comments-send"
      className={reviewing ? "comment-button comments-action-quiet" : "comment-button comment-button-primary"}
      busy={sendState === "sending"}
      disabled={entries.length === 0 || sendState === "sending"}
      idleLabel={labels.sendComments}
      busyLabel={labels.sendingComments}
      onClick={onSend}
      state={sendState}
    />
  ) : null;
  return (
    <div id="comments-section" aria-label={labels.comments}>
      <div id="comments-header">
        <span id="comments-title">{`${labels.comments} (${entries.length})`}</span>
        {reviewing ? (
          <TwoLabelButton
            id="comments-post"
            className="comment-button comment-button-primary"
            busy={postState === "posting"}
            disabled={entries.length === 0 || postState === "posting"}
            idleLabel={labels.postComments}
            busyLabel={labels.postingComments}
            onClick={onPost}
            state={postState}
          />
        ) : (
          send
        )}
      </div>
      {reviewing ? (
        <div id="comments-review">
          <ReviewReference labels={labels} posted={postState === "posted" ? posted : undefined} review={review} />
          {send}
        </div>
      ) : null}
      {sendState === "failed" ? <output id="comments-send-error">{labels.sendCommentsFailed}</output> : null}
      {reviewing && postState === "failed" ? (
        <output id="comments-post-error">
          {labels.postCommentsFailed}
          {postError ? <span className="comments-error-reason">{postError}</span> : null}
        </output>
      ) : null}
      <div id="comments-list">
        {entries.length === 0 ? (
          <div className="comments-empty">{labels.noComments}</div>
        ) : (
          entries.map((entry) => (
            <button key={entry.comment.id} type="button" className="comment-entry" onClick={() => onSelect(entry)}>
              <span className="comment-entry-header">
                <span className="comment-entry-location">{commentDisplayName(entry.comment)}</span>
                {!entry.pending && entry.anchor.state === "outdated" ? (
                  <span className="comment-entry-badge">{labels.outdatedComment}</span>
                ) : null}
              </span>
              <span className="comment-entry-message">{entry.comment.message}</span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}

/** `owner/repo#123`, the way GitHub writes a pull request's reference. */
export function pullRequestReference(review: Pick<DiffReviewTarget, "repo" | "number">): string {
  return `${review.repo}#${review.number}`;
}

/**
 * The pull request under review, as a link to it; once posted, the posted review, as a link to it.
 * One line either way (ellipsized), so the swap moves nothing.
 */
export function ReviewReference({
  labels,
  posted,
  review,
}: {
  labels: DiffCommentLabels;
  posted?: DiffReviewPosted;
  review: DiffReviewTarget;
}) {
  const pr = pullRequestReference(review);
  const done = posted != null && posted.url !== "";
  return (
    <a
      id="comments-review-link"
      href={done ? posted.url : review.url}
      target="_blank"
      rel="noreferrer"
      title={review.title}
      data-posted={done || undefined}
    >
      {fillCommentLabel(done ? labels.postedComments : labels.reviewingPullRequest, { pr })}
    </a>
  );
}

/**
 * A header action whose idle and busy labels are laid out in one cell, so the button is as wide as
 * the longer and the header never moves when it starts or stops.
 */
function TwoLabelButton({
  busy,
  busyLabel,
  className,
  disabled,
  id,
  idleLabel,
  onClick,
  state,
}: {
  busy: boolean;
  busyLabel: string;
  className: string;
  disabled: boolean;
  id: string;
  idleLabel: string;
  onClick?: () => void;
  state: string;
}) {
  return (
    <button
      type="button"
      id={id}
      className={`${className} comments-action`}
      data-state={state}
      disabled={disabled}
      onClick={onClick}
    >
      <span aria-hidden={busy}>{idleLabel}</span>
      <span aria-hidden={!busy}>{busyLabel}</span>
    </button>
  );
}
