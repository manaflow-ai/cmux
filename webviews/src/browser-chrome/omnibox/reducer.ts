// The omnibar state machine: `(state, input) -> (state, effects)`, pure (OmnibarReducer.swift).
// Each input's handling is here and in reducer-editing, -keyword, -popup, -rows and -selection.
import { fieldChanged } from "./reducer-editing";
import { leaveKeyword, keywordQuery } from "./reducer-keyword";
import { key, rowClick, rowHover, suggestionsArrived } from "./reducer-popup";
import { moreSuggestionsArrived } from "./reducer-rows";
import { fieldMouseDown, fieldMouseUp } from "./reducer-selection";
import { clamped, droppedText, singleLine } from "./rules";
import {
  canElide,
  cloneState,
  displayText,
  emptyEdit,
  emptyPopup,
  fieldText,
  hasFocus,
  isComposing,
  permanentText,
  visibleUserText,
} from "./state";
import type { OmnibarState } from "./state";
import { allOf, trimSpaces } from "./text";
import type { OmnibarDisposition, OmnibarEffect, OmnibarFocusSource, OmnibarInput, OmniboxResolver } from "./types";

/** The result of one reducer step. */
export interface OmnibarTransition {
  state: OmnibarState;
  effects: OmnibarEffect[];
  /** The input was consumed. For keys, false means the field editor runs its default. */
  handled: boolean;
}

/** One reducer step: the state being built and the effects it asks for. */
export interface OmnibarStep {
  state: OmnibarState;
  effects: OmnibarEffect[];
  handled: boolean;
  readonly resolver: OmniboxResolver;
}

/** Undo entries kept per editing session. */
export const UNDO_LIMIT = 100;

export function reduce(state: OmnibarState, input: OmnibarInput, resolver: OmniboxResolver): OmnibarTransition {
  const step: OmnibarStep = { state: cloneState(state), effects: [], handled: true, resolver };
  handle(step, input);
  return { state: step.state, effects: step.effects, handled: step.handled };
}

function handle(step: OmnibarStep, input: OmnibarInput): void {
  switch (input.type) {
    case "focusGained":
      return focusGained(step, input.source);
    case "focusLost":
      return focusLost(step);
    case "fieldChanged":
      return fieldChanged(step, input.field, input.kind);
    case "key":
      return key(step, input.key);
    case "fieldMouseDown":
      return fieldMouseDown(step, input.clickCount, input.button ?? "left", input.word ?? null);
    case "fieldMouseDragged":
      if (step.state.mouse) step.state.mouse.dragged = true;
      return;
    case "fieldMouseUp":
      return fieldMouseUp(step);
    case "rowHover":
      return rowHover(step, input.row, input.pointer);
    case "rowClick":
      return rowClick(step, input.row, input.disposition, input.shown);
    case "popupScroll":
      // At most 8 rows: the card never scrolls, the wheel is swallowed.
      return;
    case "suggestions":
      return suggestionsArrived(step, input.rows, input.generation);
    case "moreSuggestions":
      return moreSuggestionsArrived(step, input.rows, input.generation, input.capacity);
    case "pageURLChanged":
      return pageURLChanged(step, input.url);
    case "showFullURLsChanged":
      return showFullURLsChanged(step, input.full);
    case "searchEngineChanged":
      if (step.state.phase === "editing") refreshSuggestions(step, true);
      return;
    case "pasteAndGo":
      return pasteAndGo(step, input.text);
    case "dropped":
      return dropped(step, input.text);
  }
}

// Focus

function focusGained(step: OmnibarStep, source: OmnibarFocusSource): void {
  if (!hasFocus(step.state)) beginFocus(step, source);
}

/**
 * Focus arrived: the URL all selected, or the text left behind when focus last moved away.
 * Keyboard focus (Cmd-L) shows the full URL; a click or a programmatic focus keeps the
 * steady-state text until the selection changes.
 */
export function beginFocus(step: OmnibarStep, source: OmnibarFocusSource): void {
  const state = step.state;
  const retained = state.retainedText ?? "";
  const saved = state.savedSelection;
  state.retainedText = null;
  state.savedSelection = null;
  state.popup = emptyPopup();
  state.undo = [];
  state.redo = [];
  state.lastEditKind = null;
  state.doubleClickWord = null;
  if (retained === "") {
    state.editHasPaste = false;
    state.phase = "focused";
    state.elided = source !== "keyboard" && canElide(state);
    state.edit = emptyEdit({ selection: allOf(fieldText(state)) });
  } else {
    state.phase = "editing";
    state.elided = false;
    // A programmatic focus restores the saved selection; a click and Cmd-L select all.
    const selection = source === "programmatic" && saved ? clamped(saved, retained.length) : null;
    state.edit = emptyEdit({ userText: retained, selection: selection ?? allOf(retained), suppressCompletion: true });
  }
  // The field becomes first responder before the press arrives: this focus belongs to a click.
  if (source === "mouse" && state.mouse == null) {
    state.mouse = {
      pressed: false,
      clickCount: 0,
      button: "left",
      selectAllOnRelease: true,
      wordAtPress: null,
      dragged: false,
    };
  }
  step.effects.push({ type: "began" });
}

function focusLost(step: OmnibarStep): void {
  const state = step.state;
  const wasFocused = hasFocus(state);
  if (state.keyword != null) {
    // The session's text means nothing without its keyword.
    leaveKeyword(step, false);
    state.edit = emptyEdit();
  }
  if (state.phase === "editing") {
    // Chromium `OnBlur`: typed text that equals the permanent display text reverts to it.
    const text = visibleUserText(state);
    state.retainedText = text === "" || text === displayText(state) ? null : text;
    state.savedSelection = state.retainedText == null ? null : clamped(state.edit.selection, text.length);
  }
  state.phase = "idle";
  endSession(step);
  if (wasFocused) step.effects.push({ type: "ended", reason: { kind: "blur" } });
}

/** Clears everything that lives only while the field has focus. */
export function endSession(step: OmnibarStep): void {
  const state = step.state;
  state.edit = emptyEdit();
  closePopup(step);
  state.elided = false;
  state.mouse = null;
  state.doubleClickWord = null;
  state.undo = [];
  state.redo = [];
  state.lastEditKind = null;
}

// Page and commit

function pageURLChanged(step: OmnibarStep, url: string | null): void {
  const state = step.state;
  if (url === state.pageURL) return;
  state.pageURL = url;
  switch (state.phase) {
    case "idle":
      // A navigation supersedes text left behind by an earlier blur.
      state.retainedText = null;
      state.savedSelection = null;
      break;
    case "focused":
      // New permanent text while the user has not typed reverts to the display text, all selected.
      state.elided = canElide(state);
      state.edit = emptyEdit({ selection: allOf(fieldText(state)) });
      state.doubleClickWord = null;
      break;
    case "editing":
      // Never overwrite what the user typed; Escape reverts to the new URL.
      break;
    case "committing":
      state.committingDisplay = url;
      break;
  }
}

/** The full-URL setting changed: a focused field that showed the elided URL shows the full one. */
function showFullURLsChanged(step: OmnibarStep, full: boolean): void {
  const state = step.state;
  if (state.showsFullURLs === full) return;
  state.showsFullURLs = full;
  if (state.phase === "focused" && state.elided && !canElide(state)) {
    state.elided = false;
    state.edit = emptyEdit({ selection: allOf(fieldText(state)) });
  }
}

function pasteAndGo(step: OmnibarStep, text: string): void {
  // The view commits marked text first; never commit around the IME.
  if (isComposing(step.state)) {
    step.handled = false;
    return;
  }
  const trimmed = trimSpaces(singleLine(text));
  const url = trimmed ? step.resolver.destination(trimmed)?.url : null;
  if (url == null) {
    step.effects.push({ type: "beep" });
    return;
  }
  leaveKeyword(step, false);
  commit(step, url, "currentTab");
}

/** Chromium `PerformDrop`: the cleaned text replaces the box's text, all selected; it loads nothing. */
function dropped(step: OmnibarStep, text: string): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const cleaned = droppedText(text);
  if (!cleaned) {
    step.handled = false;
    return;
  }
  leaveKeyword(step, false);
  state.phase = "editing";
  state.elided = false;
  state.popup = emptyPopup();
  state.edit = emptyEdit({ userText: cleaned, selection: allOf(cleaned), suppressCompletion: true });
  state.lastEditKind = null;
  state.editHasPaste = true;
  query(step);
}

/** Loads `url` and ends editing; the chrome returns focus to the page. */
export function commit(step: OmnibarStep, url: string, disposition: OmnibarDisposition): void {
  const state = step.state;
  const here = disposition === "currentTab";
  if (here) state.pageURL = url;
  state.phase = "committing";
  state.committingDisplay = state.pageURL;
  state.retainedText = null;
  state.savedSelection = null;
  state.editHasPaste = false;
  endSession(step);
  step.effects.push({ type: "cancelQuery" });
  step.effects.push({
    type: "ended",
    reason: here ? { kind: "commit", url } : { kind: "open", url, disposition },
  });
}

/** Where Enter goes now, null when the text resolves to nothing. */
export function commitDestination(step: OmnibarStep): string | null {
  const state = step.state;
  switch (state.phase) {
    case "focused": {
      const text = permanentText(state);
      return text ? (step.resolver.destination(text)?.url ?? null) : null;
    }
    case "editing": {
      const { selected, rows, stale } = state.popup;
      if (selected != null && selected < rows.length && (selected > 0 || !stale)) return rows[selected].url;
      return step.resolver.destination(fieldText(state))?.url ?? null;
    }
    default:
      return null;
  }
}

// Suggestions

/** Asks for rows for the typed text, or closes the popup when it is blank. */
export function query(step: OmnibarStep): void {
  const state = step.state;
  if (state.keyword != null) return keywordQuery(step, state.keyword);
  if (!state.edit.userText.trim()) {
    closePopup(step);
    step.effects.push({ type: "cancelQuery" });
    return;
  }
  state.generation += 1;
  step.effects.push({ type: "query", generation: state.generation, text: state.edit.userText });
}

/**
 * The visible rows no longer match the text: they stay on screen until fresh ones arrive, but
 * Enter no longer picks them. After an edit the highlight returns to the default row;
 * `keepSelection` keeps an arrowed row (engine switch).
 */
export function refreshSuggestions(step: OmnibarStep, keepSelection = false): void {
  const popup = step.state.popup;
  if (popup.rows.length > 0) {
    popup.stale = true;
    if (!keepSelection) {
      popup.selected = 0;
      popup.hover = null;
      popup.source = "keyboard";
    }
  }
  query(step);
}

export function closePopup(step: OmnibarStep): void {
  step.state.popup = emptyPopup();
}
