import { useSettingsState, useStore } from "../context";
import { soundTitle } from "../format";
import { Icon } from "../icons";
import { t } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

export function SoundEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const sounds = useSettingsState().domains.sounds;
  const current = typeof value === "string" ? value : String(row.default ?? "default");
  const names = sounds.includes(current) ? sounds : [current, ...sounds];
  return (
    <span className="sound-editor">
      <Select value={current} disabled={disabled} labelId={labelId} onChange={(next) => void store.set(row.key, next)}>
        {names.map((name) => (
          <option key={name} value={name}>
            {soundTitle(name)}
          </option>
        ))}
      </Select>
      <button
        type="button"
        className="icon-button"
        aria-label={t("settingsPage.playSound")}
        title={t("settingsPage.playSound")}
        disabled={current === "none"}
        onClick={() => store.playSound(current)}
      >
        <Icon name="play" />
      </button>
    </span>
  );
}
