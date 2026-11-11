import { useState } from "react";
import { useStore } from "../context";
import type { SchemaRow } from "../schema";
import { locale, t } from "../strings";
import { NumberField } from "./NumberField";
import { Select } from "./Select";
import type { EditorProps } from "./types";

/** Seconds in one of a row's time units. Milliseconds rows (delays, animation times) keep their slider. */
const UNIT_SECONDS: Partial<Record<string, number>> = { seconds: 1, minutes: 60, hours: 3600, days: 86400 };

/** The durations a person thinks in, in seconds: the menu offers those the row's range and step allow. */
const PRESETS = [
  5,
  10,
  15,
  30,
  60,
  2 * 60,
  5 * 60,
  10 * 60,
  15 * 60,
  30 * 60,
  3600,
  2 * 3600,
  3 * 3600,
  6 * 3600,
  12 * 3600,
  86400,
  2 * 86400,
  3 * 86400,
  7 * 86400,
  14 * 86400,
  30 * 86400,
  90 * 86400,
  180 * 86400,
  365 * 86400,
];

/** A slider only shows travel over a short range: past this many steps a time row is a menu. */
const MAX_SLIDER_STEPS = 60;

const custom = "__custom__";

/**
 * A time row whose range is too wide for a slider (Hibernate After: 5 minutes to a week, so an hour
 * sits at the track's very start; Lucas 2026-11-11). Such a row is a menu of durations instead, as
 * macOS's own settings are ("Turn display off after").
 */
export function isDuration(row: SchemaRow): boolean {
  const range = row.range;
  if (!range || UNIT_SECONDS[range.unit] === undefined || range.step <= 0) return false;
  return (range.max - range.min) / range.step > MAX_SLIDER_STEPS;
}

/** "1 hour", "15 minutes", "2 weeks": the largest unit that holds the duration whole, in the page's language. */
export function durationLabel(seconds: number): string {
  const units: Array<[Intl.NumberFormatOptions["unit"], number]> = [
    ["week", 7 * 86400],
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  const [unit, size] = (seconds > 0 && units.find(([, size]) => seconds % size === 0)) || ["second", 1];
  return new Intl.NumberFormat(locale(), { style: "unit", unit, unitDisplay: "long" }).format(seconds / size);
}

/** The menu's values in the row's unit: the presets on its step, plus the stored value and default. */
function durations(row: SchemaRow, current: number): number[] {
  const range = row.range!;
  const factor = UNIT_SECONDS[range.unit]!;
  const onStep = (value: number) => {
    const steps = (value - range.min) / range.step;
    return Math.abs(steps - Math.round(steps)) < 1e-9;
  };
  const values = PRESETS.map((seconds) => seconds / factor).filter(
    (value) => value >= range.min && value <= range.max && onStep(value),
  );
  const fixed = [current, typeof row.default === "number" ? row.default : null].filter((v) => v !== null);
  return [...new Set([...values, ...fixed])].sort((a, b) => a - b);
}

export function DurationEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const range = row.range!;
  const factor = UNIT_SECONDS[range.unit]!;
  const [customPicked, setCustomPicked] = useState(false);
  // A new value from outside the menu (another client, the context menu's reset) ends a Custom… pick
  // that wrote nothing, so the row shows its value in the menu again.
  const [seenValue, setSeenValue] = useState(value);
  if (!Object.is(seenValue, value)) {
    setSeenValue(value);
    if (customPicked) setCustomPicked(false);
  }
  const stored = typeof value === "number" ? value : null;
  const current = stored ?? (typeof row.default === "number" ? row.default : range.placeholder);
  return (
    <span className="choice-or-number">
      {/* The field opens left of the menu, so the menu the person just used stays in place. */}
      {customPicked && (
        <NumberField
          value={stored}
          range={range}
          placeholder={String(current)}
          disabled={disabled}
          labelId={labelId}
          onCommit={(next) => {
            setCustomPicked(false);
            void store.set(row.key, next);
          }}
        />
      )}
      <Select
        value={customPicked ? custom : String(current)}
        disabled={disabled}
        labelId={labelId}
        onChange={(next) => {
          setCustomPicked(next === custom);
          if (next !== custom) void store.set(row.key, Number(next));
        }}
      >
        {durations(row, current).map((duration) => (
          <option key={duration} value={String(duration)}>
            {durationLabel(duration * factor)}
          </option>
        ))}
        <option value={custom}>{t("settingsPage.custom")}</option>
      </Select>
    </span>
  );
}
