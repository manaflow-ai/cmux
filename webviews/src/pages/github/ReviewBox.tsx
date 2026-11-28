// The person's review of the pull request shown, and their reply or resolve on one of its review
// threads. Each write goes through the host's `cmux.github.review.submit` / `thread.*` ops, which
// need a click and say an approval or a request for changes only as the person, never as the App.
import { useId, useState } from "react";
import type { Strings } from "../shared/i18n";
import type { GitHubStore } from "./store";
import { useGitHubSlice } from "./useGitHubSlice";
import type { ReviewEvent } from "./types";

const EVENTS: [ReviewEvent, string][] = [
  ["COMMENT", "github.review.comment"],
  ["APPROVE", "github.review.approve"],
  ["REQUEST_CHANGES", "github.review.requestChanges"],
];

/** Words and three verdicts under the conversation; an approval may come with no words. */
export function ReviewBox({
  prState,
  store,
  strings,
  initialBody = "",
}: {
  /** The pull request's state; the box shows only on an open one. */
  prState?: string;
  store: GitHubStore;
  strings: Strings;
  initialBody?: string;
}) {
  const { t } = strings;
  const label = useId();
  const [body, setBody] = useState(initialBody);
  const write = useGitHubSlice(store, (s) => s.write);
  if (prState !== "open") return null;
  const mine = write.phase !== "idle" && write.what === "review";
  const sending = write.phase === "sending";
  const submit = async (event: ReviewEvent) => {
    if (await store.submitReview(event, body.trim())) setBody("");
  };
  return (
    <div className="gh-review-box">
      <label className="gh-review-box-label" htmlFor={label}>
        {t("github.review.title")}
      </label>
      <textarea
        id={label}
        aria-label={t("github.review.title")}
        className="gh-review-box-text"
        rows={3}
        value={body}
        placeholder={t("github.review.placeholder")}
        disabled={sending}
        onChange={(event) => setBody(event.target.value)}
      />
      <div className="gh-review-box-actions">
        {EVENTS.map(([event, key]) => (
          <button
            key={event}
            type="button"
            className={event === "APPROVE" ? "gh-button gh-button--primary" : "gh-button"}
            disabled={sending || (event !== "APPROVE" && body.trim() === "")}
            onClick={() => void submit(event)}
          >
            {t(key)}
          </button>
        ))}
        {mine && write.phase === "sending" && <span className="gh-merge-note">{t("github.review.sending")}</span>}
        {mine && write.phase === "sent" && (
          <span className="gh-merge-note" aria-live="polite">
            {t("github.review.sent")}
          </span>
        )}
        {mine && write.phase === "failed" && (
          <span className="gh-merge-note gh-merge-failure" role="alert">
            {write.personOnly ? t("github.review.personOnly") : write.message}
          </span>
        )}
      </div>
    </div>
  );
}

/** Reply and Resolve (or Reopen) under a review comment whose thread the page read. */
export function ThreadActions({
  thread,
  resolved,
  store,
  strings,
  initialReplying = false,
}: {
  thread: string;
  resolved: boolean;
  store: GitHubStore;
  strings: Strings;
  initialReplying?: boolean;
}) {
  const { t } = strings;
  const [replying, setReplying] = useState(initialReplying);
  const [body, setBody] = useState("");
  const write = useGitHubSlice(store, (s) => s.write);
  const mine = write.phase !== "idle" && write.what === thread;
  const sending = write.phase === "sending";
  const reply = async () => {
    if (await store.replyThread(thread, body.trim())) {
      setBody("");
      setReplying(false);
    }
  };
  return (
    <div className="gh-thread-actions">
      {replying ? (
        <div className="gh-review-box">
          <textarea
            className="gh-review-box-text"
            rows={2}
            value={body}
            aria-label={t("github.thread.reply")}
            placeholder={t("github.thread.placeholder")}
            disabled={sending}
            onChange={(event) => setBody(event.target.value)}
          />
          <div className="gh-review-box-actions">
            <button
              type="button"
              className="gh-button gh-button--primary"
              disabled={sending || body.trim() === ""}
              onClick={() => void reply()}
            >
              {t("github.thread.send")}
            </button>
            <button type="button" className="gh-button" disabled={sending} onClick={() => setReplying(false)}>
              {t("github.merge.cancel")}
            </button>
          </div>
        </div>
      ) : (
        <div className="gh-review-box-actions">
          <button type="button" className="gh-fold" disabled={sending} onClick={() => setReplying(true)}>
            {t("github.thread.reply")}
          </button>
          <button
            type="button"
            className="gh-fold"
            disabled={sending}
            onClick={() => void store.resolveThread(thread, !resolved)}
          >
            {t(resolved ? "github.thread.reopen" : "github.thread.resolve")}
          </button>
        </div>
      )}
      {mine && write.phase === "failed" && (
        <span className="gh-merge-note gh-merge-failure" role="alert">
          {write.message}
        </span>
      )}
    </div>
  );
}
