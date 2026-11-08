// The omnibar's data shapes: suggestion rows the host pushes in, the resolver the host provides,
// the reducer's inputs and effects. Ported from CmuxNextBrowser/Omnibox (OmnibarInput.swift,
// UI/OmnibarEvent.swift, BrowserSuggestion.swift, BrowserSearchEngine.swift).

/** A UTF-16 range in the field text (NSRange). */
export interface TextRange {
  location: number;
  length: number;
}

export type SuggestionKind =
  /** Load the typed URL. */
  | "navigate"
  /** Search for the typed or suggested query. */
  | "search"
  | "history"
  | "bookmark"
  /** An extension's suggestion in a keyword session (`chrome.omnibox`). */
  | "keyword"
  /** An open tab of the same profile: Enter reveals it. */
  | "switchToTab"
  /** A calculator answer: Enter copies `content`, never navigates. */
  | "answer";

/** Which row a click on the card meant: its kind and URL as the card drew them. */
export interface ShownRow {
  kind: SuggestionKind;
  url: string;
}

/** One row of the suggestion card, as the native suggestion engine produces it. */
export interface BrowserSuggestion {
  kind: SuggestionKind;
  /** Main line: page title or query. */
  title: string;
  /** Second line: display URL, or empty. */
  detail: string;
  url: string;
  /** Higher ranks first. Providers use 0...1000. */
  score: number;
  /** Keyword and answer rows: the text sent to the extension or copied. */
  content?: string | null;
  /** Inline autocomplete may complete the typed text to this row. Absent means true. */
  inlineCompletable?: boolean;
  /** Switch to Tab rows: the tab to reveal. */
  tabKey?: string | null;
}

/** A web search engine (`BrowserSearchEngine`); `queryTemplate` holds `{searchTerms}`. */
export interface SearchEngine {
  id: string;
  name: string;
  queryTemplate: string;
  suggestTemplate?: string | null;
}

/** An omnibox keyword: an extension's (`chrome.omnibox`) or a search engine's (tab to search). */
export interface OmnibarKeyword {
  extensionID: string;
  keyword: string;
  /** Shown in the chip. */
  name: string;
  defaultDescription?: string | null;
  /** Set for a search engine's keyword: the session searches with it, no extension takes part. */
  searchEngine?: SearchEngine | null;
}

export type OmniboxDestination = { kind: "url"; url: string } | { kind: "search"; query: string; url: string };

/**
 * URL resolution and search fallback (`OmniboxResolver` + `BrowserURLResolver`). The reducer calls
 * it synchronously, so the host must provide a synchronous implementation.
 */
export interface OmniboxResolver {
  /** Extension keywords of the tab and the search engine keywords. */
  keywords: readonly OmnibarKeyword[];
  searchEngine: SearchEngine;
  /** `BrowserURLResolver.url(for:)`: a URL to load, or null when the text should be searched. */
  url(text: string): string | null;
  /** Where `text` goes: a URL, else a search; null when it resolves to nothing. */
  destination(text: string): OmniboxDestination | null;
  /** The URL typed `text` loads after its top-level-domain typo is fixed, or null. */
  typoFixedURL(text: string): { url: string; typedHost: string } | null;
}

/** Where a commit opens. */
export type OmnibarDisposition =
  | "currentTab"
  /** Cmd-Enter or Cmd-click: a background tab. */
  | "newBackgroundTab"
  /** Option-Enter, Shift-Cmd-Enter. */
  | "newForegroundTab"
  /** Shift-Enter. */
  | "newWindow";

export type OmnibarKey =
  | { kind: "up" }
  | { kind: "down" }
  | { kind: "tab" }
  | { kind: "backTab" }
  | { kind: "enter"; disposition: OmnibarDisposition }
  /** Control-Enter: a bare word gets `www.` and `.com`; other text commits as Enter does. */
  | { kind: "enterAddingTLD"; disposition: OmnibarDisposition }
  | { kind: "escape" }
  /** Cmd-A. Never unelides. */
  | { kind: "selectAll" }
  /** Cmd-L while the field already has focus: the full URL, all selected. */
  | { kind: "focusLocation" }
  /** Home (Shift-Home extends). Unelides even from select-all. */
  | { kind: "home"; extend: boolean }
  /** Shift-Delete: removes the highlighted history row. */
  | { kind: "deleteSuggestion" }
  | { kind: "undo" }
  | { kind: "redo" }
  /** Backspace with the caret at the start: leaves a keyword session. */
  | { kind: "backspaceAtStart" }
  /** Opt-Cmd-F: an empty keyword session of the default search engine. */
  | { kind: "searchWithDefaultEngine" };

export type OmnibarFocusSource = "mouse" | "keyboard" | "programmatic";
export type OmnibarMouseButton = "left" | "right";
export type OmnibarEditKind = "insert" | "delete" | "paste";

/** What the field editor holds right now. */
export interface OmnibarField {
  text: string;
  selection: TextRange;
  marked?: TextRange | null;
}

export interface OmnibarPoint {
  x: number;
  y: number;
}

/** Every event the omnibar reacts to. */
export type OmnibarInput =
  | { type: "focusGained"; source: OmnibarFocusSource }
  | { type: "focusLost" }
  /** `kind` is set for a text edit and null for a selection-only change. */
  | { type: "fieldChanged"; field: OmnibarField; kind: OmnibarEditKind | null }
  | { type: "key"; key: OmnibarKey }
  /** `word`: the word range under the pointer in the text the field shows at the press. */
  | { type: "fieldMouseDown"; clickCount: number; button?: OmnibarMouseButton; word?: TextRange | null }
  /** The pointer moved past the drag threshold while the press was down. */
  | { type: "fieldMouseDragged" }
  | { type: "fieldMouseUp" }
  /** `row` null: the pointer left the rows. */
  | { type: "rowHover"; row: number | null; pointer: OmnibarPoint }
  | { type: "rowClick"; row: number; disposition: OmnibarDisposition; shown?: ShownRow | null }
  | { type: "popupScroll" }
  | { type: "suggestions"; generation: number; rows: readonly BrowserSuggestion[] }
  /** Late (phase B) rows, merged without moving what is on screen. */
  | { type: "moreSuggestions"; generation: number; rows: readonly BrowserSuggestion[]; capacity: number }
  | { type: "pageURLChanged"; url: string | null }
  | { type: "showFullURLsChanged"; full: boolean }
  | { type: "searchEngineChanged" }
  | { type: "pasteAndGo"; text: string }
  /** A URL or text dropped on the focused omnibar: it replaces the text, all selected. */
  | { type: "dropped"; text: string };

/** Why the omnibar stopped editing. */
export type OmnibarEndReason =
  /** This tab loads `url`. */
  | { kind: "commit"; url: string }
  /** `url` opens in another tab or window. */
  | { kind: "open"; url: string; disposition: OmnibarDisposition }
  | { kind: "cancel" }
  | { kind: "blur" }
  /** Enter in an extension keyword session: the extension gets `text`. */
  | { kind: "keyword"; extensionID: string; text: string; disposition: OmnibarDisposition }
  /** The App reveals tab `key`. */
  | { kind: "switchToTab"; key: string };

/** Editing boundaries the App routes. */
export type OmnibarEvent = { kind: "didBeginEditing" } | { kind: "didEndEditing"; reason: OmnibarEndReason };

/** Side effects the reducer asks for; the host runs them after the reducer returns. */
export type OmnibarEffect =
  /** Ask the suggestion engine for `text`; answer with `suggestions`. */
  | { type: "query"; generation: number; text: string }
  | { type: "cancelQuery" }
  | { type: "beep" }
  | { type: "began" }
  | { type: "ended"; reason: OmnibarEndReason }
  /** Shift-Delete removed this history row: forget the page. */
  | { type: "deleteSuggestion"; url: string }
  /** Enter loaded the typed text as a URL: the visit counts as typed. */
  | { type: "typedNavigation"; url: string }
  /** Enter loads scheme-less typed text over https: fall back to http once if it cannot connect. */
  | { type: "typedHTTPSUpgrade"; url: string }
  /** Enter fixed a TLD typo in this typed host: remember it. */
  | { type: "hostTypoFixed"; typedHost: string }
  | { type: "copyAnswer"; text: string }
  | { type: "keywordStarted"; extensionID: string }
  /** The session's text changed; answer with `suggestions` of `generation`. */
  | { type: "keywordInput"; extensionID: string; text: string; generation: number }
  | { type: "keywordEnded"; extensionID: string };
