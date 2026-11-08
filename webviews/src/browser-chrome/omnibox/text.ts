// Swift string semantics the omnibar relies on: character (grapheme) counts and Foundation's
// whitespace sets. Ranges are UTF-16, which JS strings are natively.
import type { TextRange } from "./types";

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), (segment) => segment.segment);
}

/** ASCII has one grapheme per UTF-16 unit, except CR LF. */
function oneUnitPerCharacter(text: string): boolean {
  for (let index = 0; index < text.length; index++) {
    if (text.charCodeAt(index) > 0x7f) return false;
  }
  return !text.includes("\r\n");
}

/** Swift `String.count`. */
export function characterCount(text: string): number {
  return oneUnitPerCharacter(text) ? text.length : graphemes(text).length;
}

/** Swift `dropFirst(count)` on characters. */
export function dropCharacters(text: string, count: number): string {
  if (oneUnitPerCharacter(text)) return text.slice(count);
  return graphemes(text).slice(count).join("");
}

/** Swift `prefix(count)` on characters. */
export function prefixCharacters(text: string, count: number): string {
  if (oneUnitPerCharacter(text)) return text.slice(0, count);
  return graphemes(text).slice(0, count).join("");
}

const SPACES = "[^\\S\\n\\v\\f\\r\\u0085\\u2028\\u2029]+";
const LEADING_SPACES = new RegExp(`^${SPACES}`);
const TRAILING_SPACES = new RegExp(`${SPACES}$`);

/** `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks. */
export function trimSpaces(text: string): string {
  return text.replace(LEADING_SPACES, "").replace(TRAILING_SPACES, "");
}

export function hasWhitespace(text: string): boolean {
  return /\s/.test(text);
}

export const range = (location: number, length: number): TextRange => ({ location, length });

export function rangesEqual(a: TextRange | null | undefined, b: TextRange | null | undefined): boolean {
  if (a == null || b == null) return a == null && b == null;
  return a.location === b.location && a.length === b.length;
}

export const allOf = (text: string): TextRange => range(0, text.length);
export const caretAtEnd = (text: string): TextRange => range(text.length, 0);
export const upperBound = (selection: TextRange): number => selection.location + selection.length;

/** NSNotFound. */
export const NOT_FOUND = Number.MAX_SAFE_INTEGER;
