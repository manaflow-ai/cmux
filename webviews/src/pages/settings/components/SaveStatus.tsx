import { useSettingsState } from "../context";
import { t } from "../strings";

/** Each user setting and theme destination owns its feedback and failed intent. */
export function SaveStatus({ destination }: { destination: string }) {
  const { saves, connected } = useSettingsState();
  const save = saves.get(destination);
  if (!save) return null;
  return (
    <div className="save-status flex items-center gap-2 text-muted" role="status" data-save-state={save.status}>
      <span>{t(save.status === "saving" ? "settingsPage.saving" : "settingsPage.notSaved")}</span>
      {save.status === "error" && (
        <button className="link-button" type="button" data-save-retry="" disabled={!connected} onClick={save.retry}>
          {t("settingsPage.retry")}
        </button>
      )}
    </div>
  );
}
