import { useState } from "react";
import { clamp, displayNumber, parseNumber, unitLabel } from "../format";
import type { NumberRange } from "../schema";

/** A number field with its unit; commits on Return or blur, clamped to the range. */
export function NumberField({
  value,
  range,
  placeholder,
  disabled,
  labelId,
  onCommit,
}: {
  value: number | null;
  range: NumberRange | undefined;
  placeholder: string;
  disabled: boolean;
  labelId: string;
  onCommit: (value: number) => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const shown = draft ?? (value === null ? "" : displayNumber(value, range));
  const commit = () => {
    if (draft === null) return;
    setDraft(null);
    const parsed = parseNumber(draft, range);
    if (parsed === null) return;
    const next = clamp(parsed, range);
    if (next !== value) onCommit(next);
  };
  const unit = unitLabel(range);
  return (
    <span className="number-field">
      <input
        className="field number"
        type="text"
        inputMode="decimal"
        value={shown}
        placeholder={placeholder}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit();
          else if (event.key === "Escape" && draft !== null) {
            event.stopPropagation();
            setDraft(null);
          }
        }}
      />
      {unit && <span className="unit">{unit}</span>}
    </span>
  );
}
