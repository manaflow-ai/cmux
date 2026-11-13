import { useT } from "./i18n";
/// The line above the composer: why the chat has no folder, acpmux's reason, Choose Folder.
export function MissingFolder({ reason, error, onChoose }: { reason: string; error?: string; onChoose(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-missing-folder" aria-live="polite">
      {t("missingFolder.notice")} <span className="acpmux-missing-folder-reason">{reason}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onChoose}>
        {t("agentHome.choose")}
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
