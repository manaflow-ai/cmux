import { useT } from "./i18n";
import { isAgentHome, projectLabel } from "./sessionList";
import { type FolderAsk } from "./startFolderModel";
/// New Worktree's refusal above the composer: the host's reason, and Dismiss.
export function WorktreeFailure({ error, onDismiss }: { error: string; onDismiss(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      <span role="alert">{t("worktree.failedBecause", { reason: error })}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
        {t("worktree.dismiss")}
      </button>
    </output>
  );
}

/// The question above the composer, in the place of the private-folder line: what the home
/// folder means for the agent, Use Home Folder, and the way back (the private folder, or the
/// workspace's folder the chat keeps). `/` gets no Use button. `error` is the host's refusal.
export function StartFolderAsk({
  ask,
  current,
  error,
  confirming,
  onUse,
  onCancel,
}: {
  ask: FolderAsk;
  /// The chat's start folder now, when it has one (else it starts in the private folder).
  current?: string;
  error?: string;
  confirming?: boolean;
  onUse(): void;
  onCancel(): void;
}) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-start-folder-ask" aria-live="polite">
      {ask.reason === "home" ? t("startFolder.homeQuestion") : t("startFolder.root", { folder: ask.cwd })}{" "}
      {ask.reason === "home" && (
        <button type="button" className="acpmux-folder-choice-button" disabled={confirming} onClick={onUse}>
          {t("startFolder.useHome")}
        </button>
      )}{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onCancel}>
        {current && !isAgentHome(current)
          ? t("startFolder.keep", { folder: projectLabel(current) })
          : t("startFolder.usePrivate")}
      </button>
      {error && (
        <>
          {" "}
          <span role="alert">{error}</span>
        </>
      )}
    </output>
  );
}
