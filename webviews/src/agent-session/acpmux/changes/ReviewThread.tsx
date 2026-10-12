// A pull request review thread in the Branch scope (cx-ncc.77.2): its comments, each with its
// author and a link to it on GitHub. A resolved thread folds to one line the reader can open. An
// open one offers Address (cx-ncc.77.3), which sends the agent a prompt to address it.
import React from "react";
import { useT } from "../i18n";
import type { AddressState, ReviewThread as Thread } from "./reviewThreads";

export function ReviewThread({
  thread,
  address,
}: {
  thread: Thread;
  /// Address's state for this thread and its press; the view keeps the state, so a reload of
  /// the scope still shows a sent thread as sent.
  address?: { state: AddressState; run: () => void };
}) {
  const t = useT();
  const comments = (
    <ol className="acpmux-review-comments">
      {thread.comments.map((comment, index) => (
        <li key={index} className="acpmux-review-comment">
          <div className="acpmux-review-author">
            {comment.url ? (
              <a href={comment.url}>{comment.author || t("review.ghost")}</a>
            ) : (
              comment.author || t("review.ghost")
            )}
          </div>
          <div className="acpmux-review-body">{comment.body}</div>
        </li>
      ))}
    </ol>
  );
  const where = thread.line === undefined ? thread.path : `${thread.path}:${thread.line}`;
  return (
    <section
      className="acpmux-review-thread"
      aria-label={t("review.threadAt", { where })}
      data-resolved={thread.resolved ? "" : undefined}
      data-outdated={thread.outdated ? "" : undefined}
    >
      {thread.resolved ? (
        <details>
          <summary>{t("review.resolved")}</summary>
          {comments}
        </details>
      ) : (
        <>
          {(thread.outdated || thread.moved) && (
            <div className="acpmux-review-outdated">
              {thread.outdated ? t("review.outdated") : t("review.moved", { line: thread.line ?? "" })}
            </div>
          )}
          {comments}
          {address && (
            <div className="acpmux-review-actions">
              {/* One button throughout, so focus stays on it while it sends and once sent. */}
              <button
                type="button"
                className="acpmux-review-address"
                data-state={address.state.state}
                aria-label={
                  address.state.state === "sent"
                    ? t("review.sent")
                    : address.state.state === "sending"
                      ? t("review.sending")
                      : t("review.addressAt", { where })
                }
                aria-disabled={address.state.state === "sending" || address.state.state === "sent" ? true : undefined}
                onClick={() => {
                  if (address.state.state === "idle" || address.state.state === "failed") address.run();
                }}
              >
                {address.state.state === "sent"
                  ? t("review.sent")
                  : address.state.state === "sending"
                    ? t("review.sending")
                    : t("review.address")}
              </button>
              {address.state.state === "failed" && (
                <output role="alert">{t("prompt.notSent", { reason: address.state.message })}</output>
              )}
            </div>
          )}
        </>
      )}
    </section>
  );
}
