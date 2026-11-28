import { useStore } from "../context";
import type { EditorProps } from "./types";

/** The page's one switch control (a schema toggle, or a page choice such as Match System Appearance). */
export function Switch({
  checked,
  disabled,
  labelId,
  onToggle,
}: {
  checked: boolean;
  disabled: boolean;
  labelId: string;
  onToggle(next: boolean): void;
}) {
  return (
    <button
      type="button"
      role="switch"
      className="switch"
      aria-checked={checked}
      aria-labelledby={labelId}
      disabled={disabled}
      onClick={() => onToggle(!checked)}
    >
      <span className="knob" />
    </button>
  );
}

export function ToggleEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  return (
    <Switch
      checked={value === true}
      disabled={disabled}
      labelId={labelId}
      onToggle={(next) => void store.set(row.key, next)}
    />
  );
}
