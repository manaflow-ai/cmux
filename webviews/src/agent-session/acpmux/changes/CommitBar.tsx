// The Staged scope's commit bar (cx-tcwj, Codex desktop's commit box): a message the user writes or
// has the agent draft, then Commit. Progress and refusals show in the bar, never in a dialog.
import React, { useState } from "react";
import { useT } from "../i18n";

type Status = { kind: "drafting" | "committing" | "committed" } | { kind: "failed"; message: string };

const messageOf = (error: unknown, fallback: string) =>
  error instanceof Error && error.message ? error.message : fallback;

/// `commit` commits what is staged with the message; `draft` resolves with the agent's message.
/// `onCommitted` reloads the scope.
export function CommitBar({
  commit,
  draft,
  onCommitted,
}: {
  commit: (message: string) => Promise<unknown>;
  draft?: () => Promise<string>;
  onCommitted: () => void;
}) {
  const t = useT();
  const [message, setMessage] = useState("");
  const [status, setStatus] = useState<Status>();
  const busy = status?.kind === "drafting" || status?.kind === "committing";
  const canCommit = !busy && message.trim().length > 0;

  const runDraft = () => {
    if (!draft || busy) return;
    setStatus({ kind: "drafting" });
    draft().then(
      (text) => {
        if (text) {
          setMessage(text);
          setStatus(undefined);
        } else setStatus({ kind: "failed", message: t("commit.draftFailed") });
      },
      (error: unknown) => setStatus({ kind: "failed", message: messageOf(error, t("commit.draftFailed")) }),
    );
  };
  const runCommit = () => {
    if (!canCommit) return;
    setStatus({ kind: "committing" });
    commit(message).then(
      () => {
        setMessage("");
        setStatus({ kind: "committed" });
        onCommitted();
      },
      (error: unknown) => setStatus({ kind: "failed", message: messageOf(error, t("commit.failed")) }),
    );
  };

  return (
    <div className="acpmux-commit-bar">
      <textarea
        aria-label={t("commit.messageLabel")}
        placeholder={t("commit.messagePlaceholder")}
        rows={2}
        value={message}
        disabled={status?.kind === "drafting"}
        onChange={(event) => {
          setMessage(event.target.value);
          if (status?.kind === "committed" || status?.kind === "failed") setStatus(undefined);
        }}
        onKeyDown={(event) => {
          // ⌘↩ commits, as the composer sends; a plain Return is a new line of the message.
          if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && !event.nativeEvent.isComposing) {
            event.preventDefault();
            runCommit();
          }
        }}
      />
      <div className="acpmux-commit-row">
        {status?.kind === "failed" ? (
          <span className="acpmux-commit-status" role="alert">
            {status.message}
          </span>
        ) : (
          <span className="acpmux-commit-status" role="status">
            {status?.kind === "drafting"
              ? t("commit.drafting")
              : status?.kind === "committing"
                ? t("commit.committing")
                : status?.kind === "committed"
                  ? t("commit.committed")
                  : ""}
          </span>
        )}
        {draft && (
          <button type="button" className="acpmux-commit-draft" disabled={busy} onClick={runDraft}>
            {t("commit.draft")}
          </button>
        )}
        <button type="button" className="acpmux-commit-send" disabled={!canCommit} onClick={runCommit}>
          {t("commit.commit")}
        </button>
      </div>
    </div>
  );
}
