import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { Icon } from "../icons";
import { t } from "../strings";

/** A diagnostic from the settings file about this row, with the two ways out. */
export function RowNotice({
  settingKey,
  messages,
  disabled,
}: {
  settingKey: string;
  messages: string[];
  disabled: boolean;
}) {
  const store = useStore();
  const { host } = useSettingsState();
  return (
    <output className="notice" data-notice="">
      <Icon name="warning" />
      <span className="notice-text">{messages.join(" ")}</span>
      <button type="button" className="link-button" onClick={() => store.openNative("cmuxJSON")}>
        {t("settingsPage.openConfig", settingsFileName(host))}
      </button>
      <button type="button" className="link-button" disabled={disabled} onClick={() => void store.reset(settingKey)}>
        {t("settingsPage.reset")}
      </button>
    </output>
  );
}
