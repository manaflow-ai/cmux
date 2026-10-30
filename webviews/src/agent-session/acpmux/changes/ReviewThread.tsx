// A pull request review thread in the Branch scope (cx-ncc.77.2): its comments, each with its
// author and a link to it on GitHub. A resolved thread folds to one line the reader can open. An
// open one offers Address (cx-ncc.77.3), which sends the agent a prompt to address it.
import React from "react";
import { Markdown } from "../conversation/Markdown";
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
          <Markdown className="acpmux-review-body" plainCode>
            {comment.body}
          </Markdown>
        </li>
      ))}
    </ol>
  );
  // A folded thread still says who said what: the first comment's author and its opening line,
  // as plain text (no links or chips inside the summary), skipping a fence like ```suggestion.
  const first = thread.comments[0];
  const opening = first && plainLine(first.body);
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
          <summary>
            <span className="acpmux-review-summary-state">{t("review.resolved")}</span>
            {first && (
              <span className="acpmux-review-summary-text">
                {first.author || t("review.ghost")}
                {opening ? `: ${opening}` : null}
              </span>
            )}
          </summary>
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

/// A comment's first prose line without its Markdown marks: links keep their text, code and
/// emphasis lose their marks, and fence, heading and quote markers go.
function plainLine(body: string): string | undefined {
  const line = body
    .split("\n")
    .map((text) => text.trim())
    .find((text) => text && !text.startsWith("```") && !text.startsWith("~~~"));
  return line
    ?.replace(/^(?:#{1,6}\s+|[-*+]\s+|>\s*)/, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/(?<![\w*])(\*\*|__)(\S(?:.*?\S)?)\1(?![\w*])/g, "$2")
    .replace(/(?<![\w*])(\*|_)(\S(?:.*?\S)?)\1(?![\w*])/g, "$2");
}
