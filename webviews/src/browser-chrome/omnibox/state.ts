// Everything the omnibar knows, as one value (OmnibarState.swift). The reducer is the only
// writer; the field, the card and the chip are drawn from it (presentation.ts).
import { fillText } from "./rules";
import { range } from "./text";
import type {
  BrowserSuggestion,
  OmnibarEditKind,
  OmnibarKeyword,
  OmnibarMouseButton,
  OmnibarPoint,
  TextRange,
} from "./types";
import { urlDisplayText, urlEditingText } from "./url-display";

/**
 * idle: no focus; the compact page URL or the text left behind (`retainedText`).
 * focused: focused, text untouched; page URL changes replace the text.
 * editing: the user changed the text; page URL changes never touch it.
 * committing: Enter, a row click or Paste and Go loaded `committingDisplay`.
 */
export type OmnibarPhase = "idle" | "focused" | "editing" | "committing";

/** The field while focused or editing: what the user typed, and the selected completion after it. */
export interface OmnibarEdit {
  userText: string;
  inlineCompletion: string;
  selection: TextRange;
  /** IME marked range. While set, nothing completes inline and the field is never written. */
  marked: TextRange | null;
  /** The last edit deleted, cut, or happened before the end, so no inline completion may follow. */
  suppressCompletion: boolean;
}

export type OmnibarHighlightSource = "keyboard" | "mouse";

export interface OmnibarPopup {
  rows: BrowserSuggestion[];
  /** The keyboard selection. Row 0 is the default match. */
  selected: number | null;
  /** The row under a pointer that actually moved. */
  hover: number | null;
  source: OmnibarHighlightSource;
  /** Last pointer location seen over the rows; a hover at the same place is not movement. */
  pointer: OmnibarPoint | null;
  /** The rows were produced for older text. */
  stale: boolean;
}

export interface OmnibarUndoEntry {
  text: string;
  selection: TextRange;
  /** The text was the untouched page URL. */
  untouched: boolean;
}

/** How a keyword session started: what leaving it puts back in the field. */
export type OmnibarKeywordEntry = "space" | "tab" | "shortcut";

/** The mouse press the field is tracking. */
export interface OmnibarMouse {
  /** False while focus arrived from a click whose press the field has not reported yet. */
  pressed: boolean;
  clickCount: number;
  button: OmnibarMouseButton;
  /** The press focused the field: select all on release unless it dragged. */
  selectAllOnRelease: boolean;
  /** The word under a single click on the elided, all-selected URL, in elided coordinates. */
  wordAtPress: TextRange | null;
  dragged: boolean;
}

export interface OmnibarState {
  phase: OmnibarPhase;
  /** The URL shown compactly while `committing`. */
  committingDisplay: string | null;
  keyword: OmnibarKeyword | null;
  keywordEntry: OmnibarKeywordEntry;
  pageURL: string | null;
  retainedText: string | null;
  /** The selection in `retainedText` when focus left; a programmatic focus puts it back. */
  savedSelection: TextRange | null;
  edit: OmnibarEdit;
  popup: OmnibarPopup;
  /** Bumped by every suggestion query; results carry it back. */
  generation: number;
  /** `focused` only: the field shows the steady-state URL instead of the full one. */
  elided: boolean;
  mouse: OmnibarMouse | null;
  /** The word a following double-click selects, in full-URL coordinates. */
  doubleClickWord: TextRange | null;
  undo: OmnibarUndoEntry[];
  redo: OmnibarUndoEntry[];
  /** Consecutive edits of one kind share one undo entry. */
  lastEditKind: OmnibarEditKind | null;
  /** The edited text holds pasted text: Enter loads it as it is, with no typo fix. */
  editHasPaste: boolean;
  /** `browser.omnibar.showFullURLs`: the steady-state text is the full URL. */
  showsFullURLs: boolean;
  /** The user's home folder, for `~/…` file paths. Set by the host; empty shows whole paths. */
  home: string;
}

export function emptyEdit(edit: Partial<OmnibarEdit> = {}): OmnibarEdit {
  return {
    userText: "",
    inlineCompletion: "",
    selection: range(0, 0),
    marked: null,
    suppressCompletion: false,
    ...edit,
  };
}

export function emptyPopup(): OmnibarPopup {
  return { rows: [], selected: null, hover: null, source: "keyboard", pointer: null, stale: false };
}

export function initialOmnibarState(pageURL: string | null = null, options: Partial<OmnibarState> = {}): OmnibarState {
  return {
    phase: "idle",
    committingDisplay: null,
    keyword: null,
    keywordEntry: "space",
    pageURL,
    retainedText: null,
    savedSelection: null,
    edit: emptyEdit(),
    popup: emptyPopup(),
    generation: 0,
    elided: false,
    mouse: null,
    doubleClickWord: null,
    undo: [],
    redo: [],
    lastEditKind: null,
    editHasPaste: false,
    showsFullURLs: false,
    home: "",
    ...options,
  };
}

/** A copy the reducer may mutate; rows and keywords are shared, never mutated. */
export function cloneState(state: OmnibarState): OmnibarState {
  return {
    ...state,
    edit: { ...state.edit },
    popup: { ...state.popup, rows: [...state.popup.rows] },
    mouse: state.mouse && { ...state.mouse },
    undo: [...state.undo],
    redo: [...state.redo],
  };
}

export const hasFocus = (state: OmnibarState): boolean => state.phase === "focused" || state.phase === "editing";

export const isComposing = (state: OmnibarState): boolean => state.edit.marked != null;

/** The full page URL (Chromium `url_for_editing_`). */
export const permanentText = (state: OmnibarState): string => urlEditingText(state.pageURL);

/** The text the bar shows for `url` at rest: compact, or the full URL. */
export function steadyText(state: OmnibarState, url: string | null): string {
  return state.showsFullURLs ? urlEditingText(url) : urlDisplayText(url, state.home);
}

/** The steady-state page URL (Chromium `display_text_`). */
export const displayText = (state: OmnibarState): string => steadyText(state, state.pageURL);

/** Focusing may show the elided URL: it differs from the full one. */
export function canElide(state: OmnibarState): boolean {
  const permanent = permanentText(state);
  return permanent !== "" && displayText(state) !== permanent;
}

export function arrowedRow(state: OmnibarState): BrowserSuggestion | null {
  const { selected, rows } = state.popup;
  return selected != null && selected > 0 && selected < rows.length ? rows[selected] : null;
}

/** Exactly what the field must contain. */
export function fieldText(state: OmnibarState): string {
  switch (state.phase) {
    case "idle":
      return state.retainedText ?? displayText(state);
    case "committing":
      return steadyText(state, state.committingDisplay);
    case "focused":
      return state.elided ? displayText(state) : permanentText(state);
    case "editing": {
      const row = arrowedRow(state);
      return row ? fillText(row) : state.edit.userText + state.edit.inlineCompletion;
    }
  }
}

/** The selected suffix range while an inline completion shows. */
export function completionRange(state: OmnibarState): TextRange {
  return range(state.edit.userText.length, state.edit.inlineCompletion.length);
}

/** The suggestion card is on screen. */
export const isPopupOpen = (state: OmnibarState): boolean => state.phase === "editing" && state.popup.rows.length > 0;

/** The one row drawn highlighted. */
export function highlightedRow(popup: OmnibarPopup): number | null {
  const valid = (row: number | null): row is number => row != null && row >= 0 && row < popup.rows.length;
  if (popup.source === "mouse" && valid(popup.hover)) return popup.hover;
  return valid(popup.selected) ? popup.selected : null;
}

/** The arrowed row's text, else what the user typed without the inline completion. */
export function visibleUserText(state: OmnibarState): string {
  const row = arrowedRow(state);
  return row ? fillText(row) : state.edit.userText;
}
