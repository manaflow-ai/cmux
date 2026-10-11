// A pull request review thread in the Branch scope (cx-ncc.77.2): its comments, each with its
// author and a link to it on GitHub. A resolved thread folds to one line the reader can open.
import React from "react";
import { useT } from "../i18n";
import type { ReviewThread as Thread } from "./reviewThreads";

export function ReviewThread({ thread }: { thread: Thread }) {
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
          {thread.outdated && <div className="acpmux-review-outdated">{t("review.outdated")}</div>}
          {comments}
        </>
      )}
    </section>
  );
}
