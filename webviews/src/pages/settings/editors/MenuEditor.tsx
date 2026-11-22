import { useStore } from "../context";
import { text } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

/** A choice with more than three values, or one whose default is "unset" (shown as its label). */
export function MenuEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const unset = value === null || value === undefined;
  return (
    <Select
      value={unset ? "" : String(value)}
      disabled={disabled}
      labelId={labelId}
      onChange={(next) => void (next === "" ? store.reset(row.key) : store.set(row.key, next))}
    >
      {row.default === null && <option value="">{text(row.default_label)}</option>}
      {(row.choices ?? []).map((choice) => (
        <option key={choice.value} value={choice.value}>
          {text(choice.title)}
        </option>
      ))}
    </Select>
  );
}
