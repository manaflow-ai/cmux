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

/** The fewest preset durations that make a menu worth more than the slider. */
const MIN_PRESETS = 4;

const custom = "__custom__";

/** A row's unit as the name a duration label formats a zero in. */
const UNIT_NAMES: Partial<Record<string, Intl.NumberFormatOptions["unit"]>> = {
  seconds: "second",
  minutes: "minute",
  hours: "hour",
  days: "day",
};

/** The presets a row's range and step allow, in the row's unit. */
function presetsOf(row: SchemaRow): number[] {
  const range = row.range!;
  const factor = UNIT_SECONDS[range.unit]!;
  const onStep = (value: number) => {
    const steps = (value - range.min) / range.step;
    return Math.abs(steps - Math.round(steps)) < 1e-9;
  };
  return PRESETS.map((seconds) => seconds / factor).filter(
    (value) => value >= range.min && value <= range.max && onStep(value),
  );
}

/**
 * A time row whose range is too wide for a slider (Hibernate After: 5 minutes to a week, so an hour
 * sits at the track's very start; Lucas 2026-11-11). Such a row is a menu of durations instead, as
 * macOS's own settings are ("Turn display off after"), when its range spans an hour or more and the
 * menu has several durations to offer. A row whose default is 0 keeps its slider: its 0 means
 * something of its own ("no limit", "at once") that a duration menu cannot name.
 */
export function isDuration(row: SchemaRow): boolean {
  const range = row.range;
  const factor = range ? UNIT_SECONDS[range.unit] : undefined;
  if (!range || factor === undefined || range.step <= 0) return false;
  if (range.min === 0 && row.default === 0) return false;
  return (range.max - range.min) * factor >= 3600 && presetsOf(row).length >= MIN_PRESETS;
}

/** "1 hour", "15 minutes", "2 weeks": the largest unit that holds the duration whole, in the page's
 * language; a zero reads in `zeroUnit` (the row's own unit), never as seconds of a days row. */
export function durationLabel(seconds: number, zeroUnit: Intl.NumberFormatOptions["unit"] = "second"): string {
  const format = (unit: Intl.NumberFormatOptions["unit"], value: number) =>
    new Intl.NumberFormat(locale(), { style: "unit", unit, unitDisplay: "long" }).format(value);
  if (seconds === 0) return format(zeroUnit, 0);
  const units: Array<[Intl.NumberFormatOptions["unit"], number]> = [
    ["week", 7 * 86400],
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  const [unit, size] = (seconds > 0 && units.find(([, size]) => seconds % size === 0)) || ["second", 1];
  return format(unit, seconds / size);
}

/** The menu's values in the row's unit: the presets on its step, plus the stored value and default. */
function durations(row: SchemaRow, current: number): number[] {
  const fixed = [current, typeof row.default === "number" ? row.default : null].filter((v) => v !== null);
  return [...new Set([...presetsOf(row), ...fixed])].sort((a, b) => a - b);
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
        // Leaving the field without a new value (the same number, or nothing typed) writes nothing, so
        // the field closes here and the menu shows the row's value again instead of "Custom…".
        <span
          className="choice-or-number-custom"
          onBlur={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setCustomPicked(false);
          }}
        >
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
        </span>
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
            {durationLabel(duration * factor, UNIT_NAMES[range.unit])}
          </option>
        ))}
        <option value={custom}>{t("settingsPage.custom")}</option>
      </Select>
    </span>
  );
}
