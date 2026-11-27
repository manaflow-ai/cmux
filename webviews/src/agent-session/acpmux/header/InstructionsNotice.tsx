import { useT } from "../i18n";

/// Why the chat menu's Edit CLAUDE.md (or AGENTS.md) did not open: `file`, and the app's refusal code.
export type InstructionsFailure = { file: string; code?: string };

/// The line above the composer when the app refused to open the instructions file (cx-bopcl): it (or
/// the chat folder) is outside the folders the chat can open, it is not a file in the chat folder
/// (or the folder is gone), or anything else, with Dismiss. Only that last one has Retry: a file
/// outside the chat's folders, or not a file there, is refused the same at every ask, so a Retry on
/// it would be a vacuous click (Leo, 2026-11-22).
export function InstructionsNotice({
  failure,
  onRetry,
  onDismiss,
}: {
  failure: InstructionsFailure | undefined;
  onRetry(): void;
  onDismiss(): void;
}) {
  const t = useT();
  if (!failure) return null;
  const { file, code } = failure;
  const settled = code === "transport.path_outside_roots" || code === "transport.path_invalid";
  const message =
    code === "transport.path_outside_roots"
      ? t("instructions.outside", { file })
      : code === "transport.path_invalid"
        ? t("instructions.notFile", { file })
        : t("instructions.failed", { file });
  return (
    <div className="acpmux-host-error acpmux-instructions-notice" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{message}</p>
        <div className="acpmux-host-error-actions">
          {/* retry-prompt-ok: opens the file in an editor window, which the app does only on a click in the pane. */}
          {!settled && (
            <button type="button" onClick={onRetry}>
              {t("project.retry")}
            </button>
          )}
          <button type="button" data-notice-action="dismiss" onClick={onDismiss}>
            {t("git.dismiss")}
          </button>
        </div>
      </div>
    </div>
  );
}
