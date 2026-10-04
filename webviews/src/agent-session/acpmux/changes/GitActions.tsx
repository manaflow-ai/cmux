// The changes view's Commit and Push: two toolbar buttons, the commit form under the header
// (a message, Staged or All, Include new files), and one status line for the latest write: busy,
// done, or why it failed, with Retry when it may pass on a second try and Refresh when the view
// is stale.
import React, { useId, useRef, useState } from "react";
import { t } from "../i18n";
import { canPush, messageTooLong, sameNewFiles, type CommitScope, type NewFiles } from "./gitWrite";
import type { GitWrite } from "./useGitWrite";
import { useStartWhenDue } from "./useStartWhenDue";

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
  reloadKey,
}: {
  git: GitWrite;
  formOpen: boolean;
  onCloseForm: () => void;
  messageRef?: React.Ref<HTMLTextAreaElement>;
  /// Changes when the view reloads its scope; the commit form then lists new files again.
  reloadKey?: unknown;
}) {
  if (!git.available) return null;
  return (
    <>
      {formOpen && <CommitForm git={git} onClose={onCloseForm} messageRef={messageRef} reloadKey={reloadKey} />}
      <WriteStatusLine git={git} />
    </>
  );
}

/// A message, Staged or All, and with All an "Include new files" box. Ticking it lists the new
/// files from the Uncommitted diff; Commit waits until that list is shown in full. The view
/// closes the form when the commit succeeds, which drops the message; Cancel and Escape do too.
function CommitForm({
  git,
  onClose: onCloseForm,
  messageRef,
  reloadKey,
}: {
  git: GitWrite;
  onClose: () => void;
  messageRef?: React.Ref<HTMLTextAreaElement>;
  reloadKey?: unknown;
}) {
  const [message, setMessage] = useState("");
  const [scope, setScope] = useState<CommitScope>("staged");
  const [includeNew, setIncludeNew] = useState(false);
  const [newFiles, setNewFiles] = useState<NewFilesLoad>();
  const listing = useRef(0);
  const scopeName = useId();
  const busy = git.state?.phase === "busy";
  const tooLong = messageTooLong(message);
  const withNew = scope === "all" && includeNew;
  // New files are committed only after the reader has seen all of them.
  const newFilesShown = !withNew || (newFiles?.state === "loaded" && newFiles.files.skipped === 0);
  const ready = message.trim().length > 0 && !tooLong && !busy && !git.statusFailed && newFilesShown;
  const [listChanged, setListChanged] = useState(false);
  const list = (then?: (files: NewFiles) => void) => {
    const request = ++listing.current;
    setNewFiles({ state: "loading" });
    git.listNewFiles().then(
      (files) => {
        if (request !== listing.current) return;
        setNewFiles({ state: "loaded", files });
        then?.(files);
      },
      () => request === listing.current && setNewFiles({ state: "failed" }),
    );
  };
  // New files are read again at Commit: if any appeared or went since the list was shown, the
  // commit waits and the new list shows, so nothing unseen is committed.
  const submit = () => {
    if (!ready) return;
    if (!withNew || newFiles?.state !== "loaded") return void git.commit(message, scope, withNew);
    const shown = newFiles.files;
    setListChanged(false);
    list((files) => {
      if (sameNewFiles(shown, files)) void git.commit(message, scope, true);
      else setListChanged(true);
    });
  };
  const toggleNew = (on: boolean) => {
    setIncludeNew(on);
    setListChanged(false);
    if (on) list();
    else {
      listing.current += 1;
      setNewFiles(undefined);
    }
  };
  // A reload of the view's scope reads the new files again, so the list never outlives it.
  const [listedFor, setListedFor] = useState(reloadKey);
  if (listedFor !== reloadKey) {
    setListedFor(reloadKey);
    if (withNew) {
      listing.current += 1;
      setNewFiles(undefined);
      setListChanged(false);
    }
  }
  // With new files included, a list that a reload dropped (or that was never read) is read now.
  useStartWhenDue(withNew && newFiles === undefined, () => list());
  const options = [
    { value: "staged" as const, label: t("git.commit.staged") },
    { value: "all" as const, label: t("git.commit.all") },
  ];
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
        aria-invalid={tooLong}
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
      {tooLong && <span className="acpmux-git-form-note">{t("git.commit.tooLong")}</span>}
      <div className="acpmux-git-form-row">
        <div className="acpmux-git-scope" role="radiogroup" aria-label={t("git.commit.scope")}>
          {options.map(({ value, label }) => (
            <label key={value} className="acpmux-git-scope-option" data-checked={scope === value}>
              <input
                type="radio"
                aria-labelledby={`${scopeName}-${value}`}
                name={scopeName}
                value={value}
                checked={scope === value}
                disabled={busy}
                onChange={() => setScope(value)}
              />
              <span id={`${scopeName}-${value}`}>{label}</span>
            </label>
          ))}
        </div>
        {scope === "all" && (
          <label className="acpmux-git-include-new">
            <input
              type="checkbox"
              aria-labelledby={`${scopeName}-new`}
              checked={includeNew}
              disabled={busy}
              onChange={(event) => toggleNew(event.target.checked)}
            />
            <span id={`${scopeName}-new`}>{t("git.commit.includeNew")}</span>
          </label>
        )}
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
      {withNew && listChanged && (
        <span className="acpmux-git-form-note" role="alert">
          {t("git.commit.newFilesChanged")}
        </span>
      )}
      {withNew && <NewFileList files={newFiles} />}
    </form>
  );
}

type NewFilesLoad = { state: "loading" } | { state: "failed" } | { state: "loaded"; files: NewFiles };

/// The new files a commit with "Include new files" adds, as the Uncommitted diff lists them.
function NewFileList({ files }: { files?: NewFilesLoad }) {
  if (!files || files.state === "loading")
    return <span className="acpmux-git-form-note">{t("git.commit.newFilesLoading")}</span>;
  if (files.state === "failed") return <span className="acpmux-git-form-note">{t("git.commit.newFilesFailed")}</span>;
  const { paths, skipped } = files.files;
  return (
    <div className="acpmux-git-new-files">
      <span className="acpmux-git-form-note">
        {paths.length ? t("git.commit.newFiles") : t("git.commit.newFilesNone")}
      </span>
      {paths.length > 0 && (
        <ul aria-label={t("git.commit.newFiles")}>
          {paths.map((path) => (
            <li key={path}>{path}</li>
          ))}
        </ul>
      )}
      {skipped > 0 && <span className="acpmux-git-form-note">{t("git.commit.newFilesSkipped", { n: skipped })}</span>}
    </div>
  );
}

/// The latest write: busy, done, or why it failed, with Retry, Refresh and Dismiss as they apply.
/// A status read that failed shows here too, with Refresh. The `role=status` region stays
/// mounted and only its text changes, so screen readers announce busy and done; a failure is
/// its own alert.
function WriteStatusLine({ git }: { git: GitWrite }) {
  const state = git.state;
  const failed = state?.phase === "failed" ? state : undefined;
  const statusFailed = !state && git.statusFailed;
  const phase = state?.phase ?? (statusFailed ? "failed" : "idle");
  const progress =
    state?.phase === "busy"
      ? t(state.op === "commit" ? "git.commit.busy" : "git.push.busy")
      : state?.phase === "done"
        ? state.text
        : "";
  const canRefresh = failed ? failed.canRefresh : statusFailed;
  return (
    <div className="acpmux-git-status" data-phase={phase}>
      <output className="acpmux-git-status-text" aria-live="polite">
        {progress}
      </output>
      {(failed || statusFailed) && (
        <span className="acpmux-git-status-text" role="alert">
          {failed ? failed.text : t("git.statusFailed")}
        </span>
      )}
      {canRefresh && (
        <button type="button" className="acpmux-git-secondary" onClick={git.refresh}>
          {t("git.refresh")}
        </button>
      )}
      {failed?.canRetry && (
        <button type="button" className="acpmux-git-secondary" onClick={git.retry}>
          {t("git.retry")}
        </button>
      )}
      {state && state.phase !== "busy" && (
        <button type="button" className="acpmux-git-secondary" aria-label={t("git.dismiss")} onClick={git.dismiss}>
          ×
        </button>
      )}
      {failed?.failure.output && (
        <details className="acpmux-git-output">
          <summary>{t("git.output")}</summary>
          <pre>{failed.failure.output}</pre>
        </details>
      )}
    </div>
  );
}
