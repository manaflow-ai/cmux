import { intl } from "../../../ui/intl";

/// A rewind's time in seconds with one decimal, in the pane's language ("9.4", "9,4").
export function rewindSeconds(seconds: number, language: string): string {
  return intl.NumberFormat(language, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(seconds);
}
