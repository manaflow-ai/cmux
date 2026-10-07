import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

export function ResetButton({ settingKey, disabled }: { settingKey: string; disabled: boolean }) {
  const store = useStore();
  return (
    <button
      type="button"
      className="icon-button"
      data-reset=""
      aria-label={t("settingsPage.reset")}
      title={t("settingsPage.reset")}
      disabled={disabled}
      onClick={() => void store.reset(settingKey)}
    >
      <Icon name="reset" />
    </button>
  );
}
