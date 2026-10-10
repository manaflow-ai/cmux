// The control of one tunable, chosen by its `control.type` from the registry (number, bool, choice,
// color, spring). Values go to the app as they change; the app clamps them and answers the stored
// value, which the control then shows.
import { useState, type KeyboardEvent } from "react";
import { Select } from "../../ui/Select";
import type { NumberLimits, SpringValue, TunableControl, TunableRow, TunableUnit, TunableValue } from "./types";

const UNIT_SUFFIX: Record<TunableUnit, string> = {
  points: "pt",
  seconds: "s",
  fraction: "%",
  multiplier: "×",
  pointsPerSecond: "pt/s",
  count: "",
};

/** Fractions show as percentages; everything else as stored. */
function shown(value: number, unit: TunableUnit): number {
  return unit === "fraction" ? Math.round(value * 1000) / 10 : value;
}

/** A plain number text, at most four decimals (the Swift field's `TunableExport.format`). */
export function formatNumber(value: number): string {
  return String(Math.round(value * 10_000) / 10_000);
}

/** The slider position snapped to the step from the range start. */
export function snap(value: number, { min, step }: NumberLimits): number {
  if (step <= 0) return value;
  return Math.round((min + Math.round((value - min) / step) * step) * 10_000) / 10_000;
}

function NumberField({
  label,
  value,
  limits,
  onChange,
  testId,
}: {
  label: string;
  value: number;
  limits: NumberLimits;
  onChange(value: number): void;
  testId: string;
}) {
  const { min, max, step, unit } = limits;
  const text = formatNumber(shown(value, unit));
  // The draft lives only while the field has focus; leaving it without typing never rounds the value.
  const [draft, setDraft] = useState<string | null>(null);
  const commit = () => {
    if (draft === null || draft === text) return setDraft(null);
    const typed = Number(draft.replace(",", ".").trim());
    setDraft(null);
    if (Number.isFinite(typed) && draft.trim() !== "") onChange(unit === "fraction" ? typed / 100 : typed);
  };
  const keys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      commit();
      event.currentTarget.select();
    } else if (event.key === "Escape") {
      // Escape in a number field only drops the typed text, never closes the window.
      setDraft(null);
      event.preventDefault();
      event.stopPropagation();
    }
  };
  return (
    <span className="ds-number">
      <input
        type="range"
        className="ds-slider"
        aria-label={label}
        min={min}
        max={max}
        step={step > 0 ? step : "any"}
        value={Math.min(Math.max(value, min), max)}
        onChange={(event) => onChange(snap(Number(event.currentTarget.value), limits))}
        data-testid={`${testId}.slider`}
      />
      <input
        type="text"
        inputMode="decimal"
        className="ds-number-field"
        aria-label={label}
        value={draft ?? text}
        onFocus={(event) => {
          setDraft(text);
          event.currentTarget.select();
        }}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={keys}
        data-testid={`${testId}.field`}
      />
      <span className="ds-unit">{UNIT_SUFFIX[unit]}</span>
    </span>
  );
}

function isSpring(value: TunableValue): value is SpringValue {
  return typeof value === "object" && value !== null && "response" in value;
}

export function TunableControlView({ row, onChange }: { row: TunableRow; onChange(value: TunableValue): void }) {
  const control: TunableControl = row.control;
  const testId = `ds.control.${row.key}`;
  switch (control.type) {
    case "number":
      return (
        <NumberField
          label={row.label}
          value={typeof row.value === "number" ? row.value : control.min}
          limits={control}
          onChange={onChange}
          testId={testId}
        />
      );
    case "bool": {
      const on = row.value === true;
      return (
        <button
          type="button"
          role="switch"
          aria-checked={on}
          aria-label={row.label}
          className="ds-switch"
          onClick={() => onChange(!on)}
          data-testid={testId}
        >
          <span className="ds-switch-knob" />
        </button>
      );
    }
    case "choice":
    case "color":
      return (
        <Select
          label={row.label}
          value={typeof row.value === "string" ? row.value : ""}
          className="ds-select"
          options={control.options.map((option) => ({
            value: option.value,
            label: option.swatch ? (
              <span className="ds-color-option">
                <span className="ds-swatch" style={{ background: option.swatch }} />
                {option.title}
              </span>
            ) : (
              option.title
            ),
          }))}
          onChange={onChange}
        />
      );
    case "spring": {
      const spring = isSpring(row.value) ? row.value : { response: control.response.min, dampingFraction: 1 };
      return (
        <span className="ds-spring">
          <span className="ds-spring-row">
            <span className="ds-spring-label">{control.response.label}</span>
            <NumberField
              label={`${row.label} ${control.response.label}`}
              value={spring.response}
              limits={control.response}
              onChange={(response) => onChange({ ...spring, response })}
              testId={`${testId}.response`}
            />
          </span>
          <span className="ds-spring-row">
            <span className="ds-spring-label">{control.damping.label}</span>
            <NumberField
              label={`${row.label} ${control.damping.label}`}
              value={spring.dampingFraction}
              limits={control.damping}
              onChange={(dampingFraction) => onChange({ ...spring, dampingFraction })}
              testId={`${testId}.damping`}
            />
          </span>
        </span>
      );
    }
  }
}
