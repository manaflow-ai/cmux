// A pull request review thread in the Branch scope (cx-ncc.77.2): its comments, each with its
// author and a link to it on GitHub. A resolved thread folds to one line the reader can open. An
// open one offers Address (cx-ncc.77.3), which sends the agent a prompt to address it.
import React, { useState } from "react";
import { useT } from "../i18n";
import { addressPrompt, type ReviewThread as Thread } from "./reviewThreads";

type Sending = { state: "idle" | "sending" | "sent" } | { state: "failed"; message?: string };

export function ReviewThread({
  thread,
  onAddress,
}: {
  thread: Thread;
  onAddress?: (prompt: string) => Promise<unknown>;
}) {
  const t = useT();
  const [sending, setSending] = useState<Sending>({ state: "idle" });
  const address = () => {
    if (!onAddress || sending.state === "sending") return;
    setSending({ state: "sending" });
    onAddress(addressPrompt(thread)).then(
      () => setSending({ state: "sent" }),
      (error: unknown) =>
        setSending({ state: "failed", message: error instanceof Error && error.message ? error.message : undefined }),
    );
  };
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
          {onAddress && (
            <div className="acpmux-review-actions">
              {sending.state === "sent" ? (
                <output>{t("review.sent")}</output>
              ) : (
                <button
                  type="button"
                  className="acpmux-review-address"
                  aria-label={t("review.addressAt", { where })}
                  disabled={sending.state === "sending"}
                  onClick={address}
                >
                  {t("review.address")}
                </button>
              )}
              {sending.state === "failed" && <output role="alert">{sending.message ?? t("review.sendFailed")}</output>}
            </div>
          )}
        </>
      )}
    </section>
  );
}
