/// A count line's part: a worded count, or the live one drawn as its mark and number.
export type CountPart = string | { live: number; label: string };

/// The parts as plain text, for a hover or an accessible name ("1 waiting · 3 running").
export const countText = (parts: readonly CountPart[]) =>
  parts.map((part) => (typeof part === "string" ? part : part.label)).join(" · ");

/// The parts that are drawn: each count that is not zero (`n > 0 && ...` leaves false for the rest).
export const countParts = (...parts: readonly (CountPart | false | undefined)[]): CountPart[] =>
  parts.filter((part): part is CountPart => part !== false && part !== undefined);

/// The live part, or nothing when none runs.
export const live = (n: number, label: string): CountPart | false => n > 0 && { live: n, label };
