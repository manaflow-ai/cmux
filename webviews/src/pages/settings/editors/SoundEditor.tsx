import { Button } from "../../../ui/Button";
import { useSettingsSelector, useStore } from "../context";
import { soundTitle } from "../format";
import { Icon } from "../icons";
import { t } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

/** The menu item that asks for a sound file of the person's own; never a stored value. */
export const CUSTOM_SOUND = "__cmux_custom_sound__";

export function SoundEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const sounds = useSettingsSelector((state) => state.domains.sounds);
  const current = typeof value === "string" ? value : String(row.default ?? "default");
  const names = sounds.includes(current) ? sounds : [current, ...sounds];
  return (
    <span className="sound-editor">
      <Select
        value={current}
        disabled={disabled}
        labelId={labelId}
        onChange={(next) => void (next === CUSTOM_SOUND ? store.importSound(row.key) : store.set(row.key, next))}
      >
        {names.map((name) => (
          <option key={name} value={name}>
            {soundTitle(name)}
          </option>
        ))}
        <option value={CUSTOM_SOUND}>{t("settingsPage.customSound")}</option>
      </Select>
      <Button
        type="button"
        icon
        size="sm"
        variant="ghost"
        className="icon-button"
        aria-label={t("settingsPage.playSound")}
        disabled={current === "none"}
        onClick={() => store.playSound(current)}
      >
        <Icon name="play" />
      </Button>
    </span>
  );
}
