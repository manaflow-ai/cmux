import { useT } from "../i18n";
import { ErrorDetails } from "../conversation/ErrorDetails";
import { startFailureView } from "../startFailure";

/// A New Tab start that failed: who it was for, the raw words, and whether it was on this Mac.
/// `retry` runs the same request again with the same draft, folder and model.
export type NewTabStartFailure = {
  harness?: string;
  error: string;
  code?: string;
  local: boolean;
  retry?: () => void;
};

/// A failed start on New Tab says what the chat's start-failed card says (SwitchNotice.tsx), on the one
/// line every notice over the box takes: a plain sentence, a way out, and the raw words under Details. Before it was the raw error alone ("spawn
/// claude-agent-acp ENOENT"), with nothing to click: a person without Claude Code or Codex was stuck
/// (Leo, 2026-11-11: "ran into [trouble], and then there was no [...] recovery mechanism"). An agent
/// that is not on this Mac offers Install, which opens Agents setup: it installs the agent and then
/// sends the draft that is still here.
export function StartFailure({
  failure,
  name,
  onInstall,
  onDismiss,
}: {
  failure: NewTabStartFailure;
  /// The agent's display name ("Claude Code").
  name: string;
  onInstall?(): void;
  onDismiss(): void;
}) {
  const t = useT();
  const view = failure.harness
    ? startFailureView(t, {
        harness: failure.harness,
        name,
        error: failure.error,
        ...(failure.code ? { code: failure.code } : {}),
      })
    : { sentence: failure.error };
  const install = view.notInstalled && failure.local && onInstall;
  // One line, as every notice over the box is (BrowseFailure): the box below never moves for it.
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-start-failure" aria-live="polite">
      <span role="alert">{view.sentence}</span>{" "}
      {install && (
        <>
          <button type="button" className="acpmux-folder-choice-button" onClick={onInstall}>
            {t("switch.action.install")}
          </button>{" "}
        </>
      )}
      {failure.retry && (
        <>
          <button type="button" className="acpmux-folder-choice-button" onClick={failure.retry}>
            {t("switch.retry")}
          </button>{" "}
        </>
      )}
      <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
        {t("worktree.dismiss")}
      </button>
      {view.detail && (
        <>
          {" "}
          <ErrorDetails text={view.detail} className="acpmux-start-failure-details" />
        </>
      )}
    </output>
  );
}
