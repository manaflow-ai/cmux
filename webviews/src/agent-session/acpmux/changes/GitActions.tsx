// The changes view's Commit and Push: two toolbar buttons, the commit form under the header
// (a message, Staged or All), and one status line for the latest write: busy, done, or why it
// failed, with Retry when the write may pass on a second try and Refresh when HEAD moved.
import React, { useId, useState } from "react";
import { t } from "../i18n";
import { canPush, type CommitScope } from "./gitWrite";
import type { GitWrite } from "./useGitWrite";

/// Commit opens or closes the form; Push pushes the branch and shows how far it is ahead.
export function GitToolbarButtons({
  git,
  formOpen,
  onToggleForm,
}: {
  git: GitWrite;
  formOpen: boolean;
  onToggleForm: () => void;
}) {
  if (!git.available) return null;
  const busy = git.state?.phase === "busy";
  const pushable = canPush(git.status);
  const ahead = git.status?.ahead ?? 0;
  const pushLabel = !git.status
    ? t("git.push.label")
    : git.status.upstream
      ? ahead === 1
        ? t("git.push.ahead.one")
        : t("git.push.ahead.other", { n: ahead })
      : t("git.push.publish");
  const pushTitle = git.status?.detached
    ? t("git.push.detachedHead")
    : !pushable && git.status
      ? t("git.push.nothing")
      : pushLabel;
  return (
    <>
      <button
        type="button"
        className="acpmux-git-tool"
        data-tool="commit"
        aria-expanded={formOpen}
        disabled={busy}
        onClick={onToggleForm}
      >
        {t("git.commit.label")}
      </button>
      <button
        type="button"
        className="acpmux-git-tool"
        data-tool="push"
        title={pushTitle}
        aria-label={pushTitle}
        disabled={busy || !pushable}
        onClick={() => void git.push()}
      >
        {t("git.push.label")}
        {git.status?.upstream && ahead > 0 && (
          <span className="acpmux-git-ahead" aria-hidden="true">
            ↑{ahead}
          </span>
        )}
      </button>
    </>
  );
}

/// The commit form while open, then the latest write's outcome.
export function GitWriteBar({
  git,
  formOpen,
  onCloseForm,
  messageRef,
}: {
  git: GitWrite;
  formOpen: boolean;
  onCloseForm: () => void;
  messageRef?: React.Ref<HTMLTextAreaElement>;
}) {
  if (!git.available) return null;
  return (
    <>
      {formOpen && <CommitForm git={git} onClose={onCloseForm} messageRef={messageRef} />}
      <WriteStatusLine git={git} />
    </>
  );
}

/// A message and Staged or All. The view closes the form when the commit succeeds, which drops
/// the message; Cancel and Escape drop it too.
function CommitForm({
  git,
  onClose: onCloseForm,
  messageRef,
}: {
  git: GitWrite;
  onClose: () => void;
  messageRef?: React.Ref<HTMLTextAreaElement>;
}) {
  const [message, setMessage] = useState("");
  const [scope, setScope] = useState<CommitScope>("staged");
  const scopeName = useId();
  const busy = git.state?.phase === "busy";
  const ready = message.trim().length > 0 && !busy && !git.statusFailed;
  const submit = () => {
    if (ready) void git.commit(message, scope);
  };
  return (
    <form
      className="acpmux-git-form"
      aria-label={t("git.commit.form")}
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <textarea
        ref={messageRef}
        className="acpmux-git-message"
        aria-label={t("git.commit.message")}
        placeholder={t("git.commit.placeholder")}
        rows={2}
        value={message}
        disabled={busy}
        onChange={(event) => setMessage(event.target.value)}
        onKeyDown={(event) => {
          // Cmd-Return commits; Return alone adds a line for the message body. Escape closes
          // the form, not the changes view.
          if (event.key === "Enter" && event.metaKey && !event.nativeEvent.isComposing) {
            event.preventDefault();
            submit();
          } else if (event.key === "Escape" && !busy) {
            event.preventDefault();
            event.stopPropagation();
            onCloseForm();
          }
        }}
      />
      <div className="acpmux-git-form-row">
        <div className="acpmux-git-scope" role="radiogroup" aria-label={t("git.commit.scope")}>
          {(["staged", "all"] as const).map((value) => (
            <label key={value} className="acpmux-git-scope-option" data-checked={scope === value}>
              <input
                type="radio"
                aria-label={t(value === "staged" ? "git.commit.staged" : "git.commit.all")}
                name={scopeName}
                value={value}
                checked={scope === value}
                disabled={busy}
                onChange={() => setScope(value)}
              />
              {t(value === "staged" ? "git.commit.staged" : "git.commit.all")}
            </label>
          ))}
        </div>
        <span className="acpmux-git-scope-hint">
          {t(scope === "staged" ? "git.commit.stagedHint" : "git.commit.allHint")}
        </span>
        <button type="button" className="acpmux-git-secondary" disabled={busy} onClick={onCloseForm}>
          {t("git.cancel")}
        </button>
        <button type="submit" className="acpmux-git-primary" disabled={!ready}>
          {t("git.commit.submit")}
        </button>
      </div>
    </form>
  );
}

/// The latest write: busy, done, or why it failed, with Retry, Refresh and Dismiss as they apply.
function WriteStatusLine({ git }: { git: GitWrite }) {
  const state = git.state;
  if (!state) return null;
  return (
    <div
      className="acpmux-git-status"
      data-phase={state.phase}
      role={state.phase === "failed" ? "alert" : "status"}
      aria-live={state.phase === "failed" ? "assertive" : "polite"}
    >
      <span className="acpmux-git-status-text">
        {state.phase === "busy" ? t(state.op === "commit" ? "git.commit.busy" : "git.push.busy") : state.text}
      </span>
      {state.phase === "failed" && state.failure.reason === "head_moved" && (
        <button type="button" className="acpmux-git-secondary" onClick={git.refresh}>
          {t("git.refresh")}
        </button>
      )}
      {state.phase === "failed" && state.canRetry && (
        <button type="button" className="acpmux-git-secondary" onClick={git.retry}>
          {t("git.retry")}
        </button>
      )}
      {state.phase !== "busy" && (
        <button type="button" className="acpmux-git-secondary" aria-label={t("git.dismiss")} onClick={git.dismiss}>
          ×
        </button>
      )}
      {state.phase === "failed" && state.failure.output && (
        <details className="acpmux-git-output">
          <summary>{t("git.output")}</summary>
          <pre>{state.failure.output}</pre>
        </details>
      )}
    </div>
  );
}
