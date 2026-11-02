import { translate, useT } from "./i18n";
import { errorMessage } from "./transportErrors";

/// Native folder chooser failures use a transport code when one is available. Keep the shared
/// fallback localized and useful when a host gives us no displayable reason.
export function browseFailureMessage(error: unknown): string {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  if (code === "unsupported") return translate("project.unavailable");
  return errorMessage(error).trim() || translate("project.unavailable");
}

/// A native folder chooser can fail after its menu has closed. Keep the start surface mounted and
/// put the reason beside a direct retry, so a transient host refusal does not strand the draft.
export function BrowseFailure({ error, onRetry, onDismiss }: { error: string; onRetry(): void; onDismiss(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice" aria-live="polite">
      <span role="alert">{error}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onRetry}>
        {t("project.retry")}
      </button>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
        {t("worktree.dismiss")}
      </button>
    </output>
  );
}
