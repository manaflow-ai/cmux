import { type PaneLanguage } from "../i18n";

/// The cap's window in words, in the pane language: "10 minutes", "2 hours", "90 seconds" (the
/// largest unit that divides it).
export function spelledWindow(seconds: number, language: PaneLanguage): string {
  const [unit, value] =
    seconds >= 3600 && seconds % 3600 === 0
      ? (["hour", seconds / 3600] as const)
      : seconds >= 60 && seconds % 60 === 0
        ? (["minute", seconds / 60] as const)
        : (["second", seconds] as const);
  return new Intl.NumberFormat(language, { style: "unit", unit, unitDisplay: "long" }).format(value);
}
