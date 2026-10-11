import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

/**
 * A row's Reset control in a slot every row reserves, so it never moves the row's other
 * controls. It fades and scales in while the value differs from the default; at the default it
 * stays in place, inert and hidden from assistive technology.
 */
export function ResetButton({
  settingKey,
  shown,
  disabled,
  label = t("settingsPage.reset"),
}: {
  settingKey: string;
  shown: boolean;
  disabled: boolean;
  label?: string;
}) {
  const store = useStore();
  return (
    <span className="reset-slot" data-shown={shown ? "" : undefined}>
      <button
        type="button"
        className="icon-button reset-button"
        data-reset={shown ? "" : undefined}
        aria-label={label}
        aria-hidden={shown ? undefined : true}
        inert={!shown}
        title={label}
        disabled={disabled}
        onClick={() => void store.reset(settingKey)}
      >
        <Icon name="reset" />
      </button>
    </span>
  );
}
