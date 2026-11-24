// The New Tab clock's look and its time text (NewTabClock.tsx, `tabs.newTabClock.*`): no React here, so
// the handshake reader (newTabModel.ts) can read it without the component.

import { intl } from "../../../ui/intl";

export const CLOCK_FONTS = ["rounded", "system", "serif", "mono", "condensed"] as const;
export const CLOCK_WEIGHTS = ["thin", "regular", "bold", "heavy"] as const;
export const CLOCK_COLORS = ["text", "accent", "muted", "glass"] as const;
export type ClockFont = (typeof CLOCK_FONTS)[number];
export type ClockWeight = (typeof CLOCK_WEIGHTS)[number];
export type ClockColor = (typeof CLOCK_COLORS)[number];

/// The clock's look, from the handshake (`newTab.clock`); absent: no clock (the default).
export type NewTabClockStyle = {
  font: ClockFont;
  weight: ClockWeight;
  color: ClockColor;
  /// The date line over the time ("Monday, November 16").
  date: boolean;
};

const pick = <T extends string>(values: readonly T[], value: unknown, fallback: T): T =>
  values.includes(value as T) ? (value as T) : fallback;

/// Reads `newTab.clock`: `{font, weight, color, date}` (Swift AgentPaneNewTabClock), or nothing for no
/// clock. A value that is no choice reads as the setting's default.
export function readClockStyle(value: unknown): NewTabClockStyle | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const { font, weight, color, date } = value as Record<string, unknown>;
  return {
    font: pick(CLOCK_FONTS, font, "rounded"),
    weight: pick(CLOCK_WEIGHTS, weight, "bold"),
    color: pick(CLOCK_COLORS, color, "text"),
    date: date !== false,
  };
}

/// The time as the Lock Screen shows it: hours and minutes in the locale's 12- or 24-hour form,
/// without the AM/PM mark.
export function clockTime(at: Date, locale?: string): string {
  return intl
    .DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" })
    .formatToParts(at)
    .filter((part) => part.type !== "dayPeriod")
    .map((part) => part.value)
    .join("")
    .trim();
}

export function clockDate(at: Date, locale?: string): string {
  return intl.DateTimeFormat(locale, { weekday: "long", month: "long", day: "numeric" }).format(at);
}

/// Milliseconds from `now` to the next minute boundary: the clock redraws once a minute, on the minute.
export function msToNextMinute(now: number): number {
  return 60_000 - (now % 60_000) || 60_000;
}
