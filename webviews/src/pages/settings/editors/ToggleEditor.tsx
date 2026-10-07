import { useStore } from "../context";
import type { EditorProps } from "./types";

export function ToggleEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const on = value === true;
  return (
    <button
      type="button"
      role="switch"
      className="switch"
      aria-checked={on}
      aria-labelledby={labelId}
      disabled={disabled}
      onClick={() => void store.set(row.key, !on)}
    >
      <span className="knob" />
    </button>
  );
}
