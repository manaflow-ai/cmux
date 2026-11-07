// Omnibox keywords (OmnibarKeyword.swift): typing a keyword and a space, or Tab after the exact
// keyword, starts a session that holds only the text after the keyword.
import { characterCount, dropCharacters, prefixCharacters } from "./text";
import type { BrowserSuggestion, OmnibarKeyword } from "./types";

/** The keyword `text` starts, followed by a space, and the text after that space. Case-insensitive. */
export function matchKeyword(
  text: string,
  keywords: readonly OmnibarKeyword[],
): { keyword: OmnibarKeyword; rest: string } | null {
  const count = characterCount(text);
  for (const keyword of keywords) {
    if (!keyword.keyword) continue;
    const prefix = `${keyword.keyword} `;
    const prefixCount = characterCount(prefix);
    if (count < prefixCount || prefixCharacters(text, prefixCount).toLowerCase() !== prefix.toLowerCase()) continue;
    return { keyword, rest: dropCharacters(text, prefixCount) };
  }
  return null;
}

/**
 * The keyword `text` is exactly (Tab starts its session). A search engine's keyword also matches
 * its site as the field shows a completed address (`www.youtube.com/`, `youtube.com/`).
 */
export function exactKeyword(text: string, keywords: readonly OmnibarKeyword[]): OmnibarKeyword | null {
  const lowered = text.toLowerCase();
  const exact = keywords.find((k) => k.keyword && k.keyword.toLowerCase() === lowered);
  if (exact) return exact;
  let host = lowered;
  for (const prefix of ["https://", "http://", "www."]) {
    if (host.startsWith(prefix)) host = host.slice(prefix.length);
  }
  if (host.endsWith("/")) host = host.slice(0, -1);
  return keywords.find((k) => k.searchEngine != null && k.keyword && k.keyword.toLowerCase() === host) ?? null;
}

/** A suggestion row of an extension: `content` goes into the field and to the extension. */
export function keywordSuggestionRow(
  extensionID: string,
  content: string,
  description: string,
  rank: number,
): BrowserSuggestion {
  const path = encodeURI(`/${content}`).replace(/[?#]/g, (c) => (c === "?" ? "%3F" : "%23"));
  return {
    kind: "keyword",
    title: description ? description : content,
    detail: !description || description === content ? "" : content,
    url: `cmux-omnibox://${extensionID || "extension"}${path}`,
    score: 1000 - rank,
    content,
  };
}

export function keywordsEqual(a: OmnibarKeyword | null | undefined, b: OmnibarKeyword | null | undefined): boolean {
  if (a == null || b == null) return a == null && b == null;
  const ea = a.searchEngine;
  const eb = b.searchEngine;
  const enginesEqual =
    ea == null || eb == null
      ? ea == null && eb == null
      : ea.id === eb.id &&
        ea.name === eb.name &&
        ea.queryTemplate === eb.queryTemplate &&
        (ea.suggestTemplate ?? null) === (eb.suggestTemplate ?? null);
  return (
    a.extensionID === b.extensionID &&
    a.keyword === b.keyword &&
    a.name === b.name &&
    (a.defaultDescription ?? null) === (b.defaultDescription ?? null) &&
    enginesEqual
  );
}
