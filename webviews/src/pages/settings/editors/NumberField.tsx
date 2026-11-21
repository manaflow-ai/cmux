import { useState } from "react";
import { Input } from "../../../ui/Input";
import { clamp, displayNumber, parseNumber, unitLabel } from "../format";
import type { NumberRange } from "../schema";

/** A number field with its unit; commits on Return or blur, clamped to the range. `inherited`
 * (an unset row's effective value) shows dimmed in place of the placeholder. */
export function NumberField({
  value,
  inherited = null,
  range,
  placeholder,
  disabled,
  labelId,
  onCommit,
}: {
  value: number | null;
  inherited?: number | null;
  range: NumberRange | undefined;
  placeholder: string;
  disabled: boolean;
  labelId: string;
  onCommit: (value: number) => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const resting = value ?? inherited;
  const shown = draft ?? (resting === null ? "" : displayNumber(resting, range));
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
      {/* The hidden copy of the longer of the shown text and the placeholder in the same grid cell
          sets the field's width, so a long default label ("Configurazione di Ghostty") is never
          cut, and typing over it never shrinks the field and moves the slider beside it. */}
      <span className="number-sizer" data-value={sizerText(shown, placeholder)}>
        <Input
          className="field number"
          data-inherited={draft === null && value === null && inherited !== null ? "" : undefined}
          type="text"
          inputMode="decimal"
          render={<input size={1} aria-labelledby={labelId} />}
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
      </span>
      {unit && <span className="unit">{unit}</span>}
    </span>
  );
}

/** The text the field sizes to: the longer of the two. */
function sizerText(shown: string, placeholder: string): string {
  return placeholder.length > shown.length ? placeholder : shown;
}
