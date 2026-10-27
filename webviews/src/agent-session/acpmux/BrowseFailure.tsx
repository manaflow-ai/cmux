import { useT } from "./i18n";

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
