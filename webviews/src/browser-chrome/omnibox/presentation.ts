// What the field, the suggestion card and the leading chip show for a state
// (OmnibarPresentation.swift). The effect applier writes it; nothing else writes the field.
import { clamped } from "./rules";
import { fieldText, hasFocus, highlightedRow, isPopupOpen, permanentText } from "./state";
import type { OmnibarState } from "./state";
import type { BrowserSuggestion, TextRange } from "./types";

export type OmnibarStyle =
  /** The compact URL, host at full strength, the rest dimmed. */
  | { kind: "compactURL"; url: string | null }
  /** Plain text at full strength (editing, retained text). */
  | { kind: "plain" };

/**
 * The leading button: the page's security indicator, or while user input is in progress an icon
 * for that input. Only user input replaces the page indicator, so focusing moves nothing.
 */
export type OmnibarChip =
  | { kind: "input"; symbol: string }
  | { kind: "page" }
  /** An extension keyword session: the extension's name. */
  | { kind: "keyword"; name: string }
  /** A search engine keyword session: "Search YouTube". */
  | { kind: "engineKeyword"; label: string };

export interface OmnibarPresentation {
  text: string;
  style: OmnibarStyle;
  /** The field editor's selection; null while the field has no focus. */
  selection: TextRange | null;
  /** Rows on screen; empty means the card is closed. */
  rows: readonly BrowserSuggestion[];
  highlighted: number | null;
  hasFocus: boolean;
  chip: OmnibarChip;
}

/** `PageInfoIndicator.searchSymbol`. */
export const SEARCH_SYMBOL = "browser.omnibox.search";
export const GLOBE_SYMBOL = "globe";

/** Chromium's `IDS_OMNIBOX_KEYWORD_TEXT`; the host may pass its localized form. */
export const searchKeywordLabel = (engine: string): string => `Search ${engine}`;

export function presentation(
  state: OmnibarState,
  labelForEngine: (engine: string) => string = searchKeywordLabel,
): OmnibarPresentation {
  const text = fieldText(state);
  const focused = hasFocus(state);
  let style: OmnibarStyle;
  switch (state.phase) {
    case "idle":
      style = state.retainedText == null ? { kind: "compactURL", url: state.pageURL } : { kind: "plain" };
      break;
    case "committing":
      style = { kind: "compactURL", url: state.committingDisplay };
      break;
    default:
      style = { kind: "plain" };
  }
  const open = isPopupOpen(state);
  return {
    text,
    style,
    selection: focused ? clamped(state.edit.selection, text.length) : null,
    rows: open ? state.popup.rows : [],
    highlighted: open ? highlightedRow(state.popup) : null,
    hasFocus: focused,
    chip: chip(state, labelForEngine),
  };
}

function chip(state: OmnibarState, labelForEngine: (engine: string) => string): OmnibarChip {
  const search: OmnibarChip = { kind: "input", symbol: SEARCH_SYMBOL };
  const keyword = state.keyword;
  if (keyword && hasFocus(state)) {
    return keyword.searchEngine == null
      ? { kind: "keyword", name: keyword.name }
      : { kind: "engineKeyword", label: labelForEngine(keyword.name) };
  }
  switch (state.phase) {
    case "editing": {
      const row = highlightedRow(state.popup);
      if (row == null) return search;
      return state.popup.rows[row].kind === "search" ? search : { kind: "input", symbol: GLOBE_SYMBOL };
    }
    case "focused":
      // An empty box (the New Tab page) shows the search icon, at rest and focused alike.
      return permanentText(state) === "" ? search : { kind: "page" };
    default:
      return fieldText(state) === "" || state.retainedText != null ? search : { kind: "page" };
  }
}
