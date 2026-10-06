// Display text for values: choice titles, numbers with units, percent for fractions.
import { locale, t, text, unitSuffix } from "./strings";
import type { NumberRange, SchemaRow } from "./schema";

export function isFraction(range: NumberRange | undefined): boolean {
  return range?.unit === "fraction";
}

/** The number shown in a field: fractions as percent, rounded to the step's precision. */
export function displayNumber(value: number, range: NumberRange | undefined): string {
  const shown = isFraction(range) ? value * 100 : value;
  return String(Math.round(shown * 1000) / 1000);
}

/** Parses a field's text back into a stored number, or null. */
export function parseNumber(input: string, range: NumberRange | undefined): number | null {
  const number = Number(input.trim().replace(",", "."));
  if (input.trim() === "" || !Number.isFinite(number)) return null;
  return isFraction(range) ? number / 100 : number;
}

export function clamp(value: number, range: NumberRange | undefined): number {
  if (!range) return value;
  return Math.min(range.max, Math.max(range.min, value));
}

/** The unit beside a number field ("pt", "s", "min", "%", or nothing for counts). */
export function unitLabel(range: NumberRange | undefined): string {
  switch (range?.unit) {
    case "points":
      return unitSuffix("settingsPage.points");
    case "seconds":
      return unitSuffix("settingsPage.seconds");
    case "minutes":
      return unitSuffix("settingsPage.minutes");
    case "fraction":
      return (
        new Intl.NumberFormat(locale(), { style: "percent" })
          .formatToParts(1)
          .find((part) => part.type === "percentSign")?.value ?? "%"
      );
    default:
      return "";
  }
}

/** Searchable text of a row's current value. */
export function valueText(row: SchemaRow, value: unknown): string {
  if (value === null || value === undefined) return text(row.default_label);
  const choice = row.choices?.find((item) => item.value === value);
  if (choice) return `${text(choice.title)} ${choice.value}`;
  if (row.kind === "sound") return soundTitle(String(value));
  if (typeof value === "number") return `${displayNumber(value, row.range)} ${unitLabel(row.range)}`;
  if (typeof value === "boolean") return "";
  if (Array.isArray(value)) return value.join(" ");
  if (typeof value === "object") return Object.values(value).join(" ");
  return String(value);
}

export function soundTitle(name: string): string {
  if (name === "default") return t("settingsPage.soundDefault");
  if (name === "none") return t("settingsPage.soundNone");
  return name;
}
