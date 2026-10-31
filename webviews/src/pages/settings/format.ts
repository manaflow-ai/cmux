// Display text for values: choice titles, numbers with units, percent for fractions.
import { locale, t, text, unitSuffix } from "./strings";
import type { HostLists } from "./ops";
import type { NumberRange, SchemaRow } from "./schema";

/** The settings file's name from the path the app loaded (cmux-next.json, or the file
 * CMUX_NEXT_CONFIG_FILE names); "Settings File" until the host lists arrive. */
export function settingsFileName(host: HostLists | null): string {
  return host?.settings_file?.split("/").at(-1) || t("settingsWindow.settingsFile");
}

export function isFraction(range: NumberRange | undefined): boolean {
  return range?.unit === "fraction";
}

/** The unit a duration is shown in: never more digits than it needs (Leo 2026-10-30, Check Every
 * read "3600 s": "look for wastage"). The stored value and the schema's unit do not change; the page
 * converts only where it shows and reads the number (design/settings.md, "Human units"). */
type ShownUnit = NumberRange["unit"] | "hours";

const MINUTE = 60;
const QUARTER_HOUR = 15 * MINUTE;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/**
 * The unit a range is shown in, and how many stored units make one shown unit. A seconds range
 * whose bounds and step are whole quarter hours and that reaches a day reads in hours (Check Every:
 * 15 min to a week, "1 hr"); one in whole minutes reads in minutes ("10 min"); a finer one stays
 * in seconds. A minutes range of whole quarter hours that reaches a day reads in hours too.
 */
export function shownUnit(range: NumberRange | undefined): { unit: ShownUnit | undefined; factor: number } {
  const unit = range?.unit;
  if (!range || (unit !== "seconds" && unit !== "minutes")) return { unit, factor: 1 };
  const seconds = unit === "seconds" ? 1 : MINUTE;
  const whole = (span: number) => (range.min * seconds) % span === 0 && (range.step * seconds) % span === 0;
  if (whole(QUARTER_HOUR) && range.max * seconds >= DAY) return { unit: "hours", factor: HOUR / seconds };
  if (unit === "seconds" && whole(MINUTE)) return { unit: "minutes", factor: MINUTE };
  return { unit, factor: 1 };
}

/** The number shown in a field: fractions as percent, durations in their shown unit, rounded to the
 * step's precision. */
export function displayNumber(value: number, range: NumberRange | undefined): string {
  const shown = isFraction(range) ? value * 100 : value / shownUnit(range).factor;
  return String(Math.round(shown * 1000) / 1000);
}

/** Parses a field's text (in the shown unit) back into a stored number, or null. */
export function parseNumber(input: string, range: NumberRange | undefined): number | null {
  const number = Number(input.trim().replace(",", "."));
  if (input.trim() === "" || !Number.isFinite(number)) return null;
  return isFraction(range) ? number / 100 : number * shownUnit(range).factor;
}

export function clamp(value: number, range: NumberRange | undefined): number {
  if (!range) return value;
  return Math.min(range.max, Math.max(range.min, value));
}

/** The unit beside a number field ("pt", "ms", "s", "min", "hr", "days", "%", or nothing for counts). */
export function unitLabel(range: NumberRange | undefined): string {
  switch (shownUnit(range).unit) {
    case "points":
      return unitSuffix("settingsPage.points");
    case "milliseconds":
      // The short millisecond unit of the page's locale ("ms"), from Intl.
      return (
        new Intl.NumberFormat(locale(), { style: "unit", unit: "millisecond", unitDisplay: "short" })
          .formatToParts(2)
          .find((part) => part.type === "unit")?.value ?? "ms"
      );
    case "seconds":
      return unitSuffix("settingsPage.seconds");
    case "minutes":
      return unitSuffix("settingsPage.minutes");
    case "hours":
      // The short hour unit of the page's locale ("hr"), from Intl.
      return (
        new Intl.NumberFormat(locale(), { style: "unit", unit: "hour", unitDisplay: "short" })
          .formatToParts(2)
          .find((part) => part.type === "unit")?.value ?? "h"
      );
    case "days":
      // The plural day unit of the page's locale ("days", "日"), from Intl.
      return (
        new Intl.NumberFormat(locale(), { style: "unit", unit: "day", unitDisplay: "long" })
          .formatToParts(2)
          .find((part) => part.type === "unit")?.value ?? ""
      );
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
  // A map (browser.siteEngines) is found by its keys too: "spotify.com webkit".
  if (typeof value === "object") return Object.entries(value).flat().join(" ");
  return String(value);
}

export function soundTitle(name: string): string {
  if (name === "default") return t("settingsPage.soundDefault");
  if (name === "none") return t("settingsPage.soundNone");
  return name;
}
