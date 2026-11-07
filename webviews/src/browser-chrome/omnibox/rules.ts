// Text rules the omnibar state machine uses (OmnibarRules.swift): Chromium's autocomplete rules,
// reduced to what cmux needs. Pure functions.
import { characterCount, dropCharacters, hasWhitespace, NOT_FOUND, trimSpaces } from "./text";
import type { BrowserSuggestion, TextRange } from "./types";
import { parseURL, urlDisplayText, urlEditingText, urlScheme } from "./url-display";

/** Text a row puts in the field when it is selected with the arrow keys. */
export function fillText(row: BrowserSuggestion): string {
  switch (row.kind) {
    case "search":
      return row.title;
    case "keyword":
    case "answer":
      return row.content ?? row.title;
    default:
      return urlEditingText(row.url);
  }
}

/**
 * The suffix that completes `typed` to `row`'s URL, or null. Only navigation, history and bookmark
 * rows marked inline-completable complete, only on a prefix of the URL as shown or of the full
 * URL, and never for a trailing space.
 */
export function inlineCompletion(row: BrowserSuggestion, typed: string, home = ""): string | null {
  if (row.inlineCompletable === false) return null;
  if (row.kind === "search" || row.kind === "keyword" || row.kind === "switchToTab" || row.kind === "answer")
    return null;
  if (!typed || /\s$/u.test(typed)) return null;
  const lowered = typed.toLowerCase();
  const typedCount = characterCount(typed);
  for (const form of completionForms(row.url, home)) {
    if (form.toLowerCase().startsWith(lowered) && characterCount(form) > typedCount) {
      return dropCharacters(form, typedCount);
    }
  }
  return null;
}

/** The compact display text and the full URL (for users who type the scheme). */
function completionForms(url: string, home: string): string[] {
  const full = url.endsWith("/") && parseURL(url)?.path === "/" ? url.slice(0, -1) : url;
  return [urlDisplayText(url, home), full].filter((form) => form !== "");
}

/**
 * The Control-Enter URL for `typed`: `www.` and `.com` around a host without a dot (`example`,
 * `google/maps`, `www.example`), null for anything else.
 */
export function desiredTLDURL(typed: string, resolveURL: (text: string) => string | null): string | null {
  const text = trimSpaces(typed);
  if (!text || hasWhitespace(text) || text.includes(":")) return null;
  const end = text.search(/[/?#]/);
  const hostEnd = end < 0 ? text.length : end;
  let host = text.slice(0, hostEnd).toLowerCase();
  if (host.startsWith("www.")) host = host.slice(4);
  if (!host || host.includes(".") || host.includes("@") || !/^[\p{L}\p{N}-]+$/u.test(host)) return null;
  return resolveURL(`www.${host}.com${text.slice(hostEnd)}`);
}

/** Pasted text on one line: every line break becomes a space, so UTF-16 offsets stay. */
export function singleLine(text: string): string {
  return text.replace(/[\n\v\f\r\u0085\u2028\u2029]/g, " ");
}

/**
 * Text dropped on the omnibox, cleaned as Chromium's `PerformDrop` does: whitespace runs become
 * one space, the ends are trimmed, and leading `javascript:` schemes are stripped.
 */
export function droppedText(text: string): string {
  let cleaned = text.split(/\s+/u).filter(Boolean).join(" ");
  const scheme = "javascript:";
  while (cleaned.toLowerCase().startsWith(scheme)) cleaned = trimSpaces(cleaned.slice(scheme.length));
  return cleaned;
}

/** `selection` limited to a text of `length` UTF-16 units. A caret stays a caret at its location. */
export function clamped(selection: TextRange, length: number): TextRange {
  if (selection.location === NOT_FOUND) return { location: length, length: 0 };
  const location = Math.min(Math.max(selection.location, 0), length);
  return { location, length: Math.min(Math.max(selection.length, 0), length - location) };
}

/** `url` is the https upgrade of scheme-less typed `text`: it resolves to this https URL by itself. */
export function isHTTPSUpgrade(text: string, url: string, resolveURL: (text: string) => string | null): boolean {
  const trimmed = trimSpaces(text);
  if (urlScheme(url) !== "https" || trimmed.includes("://")) return false;
  return resolveURL(trimmed) === url;
}
