import { useStore } from "../context";
import { text } from "../strings";
import type { EditorProps } from "./types";

/** A choice with up to three values and a non-null default: native radios drawn as segments. */
export function SegmentedEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  return (
    <fieldset className="segmented" aria-labelledby={labelId}>
      {(row.choices ?? []).map((choice) => (
        <label key={choice.value} className="segment" data-checked={value === choice.value ? "" : undefined}>
          <input
            type="radio"
            name={`${labelId}-choice`}
            value={choice.value}
            aria-label={text(choice.title)}
            checked={value === choice.value}
            disabled={disabled}
            onChange={() => void store.set(row.key, choice.value)}
          />
          {text(choice.title)}
        </label>
      ))}
    </fieldset>
  );
}
