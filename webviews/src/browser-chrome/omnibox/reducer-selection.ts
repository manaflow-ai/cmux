// Selection rules: the focusing click, drags and multi-clicks, right-click, select-all, Home, and
// steady-state elision (OmnibarReducer+Selection.swift; Chromium omnibox_view_views.cc).
import { refreshSuggestions } from "./reducer";
import type { OmnibarStep } from "./reducer";
import { leaveKeyword } from "./reducer-keyword";
import { clamped } from "./rules";
import { arrowedRow, fieldText, hasFocus, isComposing, permanentText } from "./state";
import type { OmnibarMouse } from "./state";
import { allOf, range, rangesEqual, upperBound } from "./text";
import type { OmnibarMouseButton, TextRange } from "./types";

/** How a selection change asks to show the full URL (Chromium `UnelisionGesture`). */
export type OmnibarUnelision = "home" | "mouseRelease" | "other";

// Mouse

/**
 * `OnMousePressed`: a press that focuses the field selects all on release; a right press selects
 * all at once, because the context menu opens on the press.
 */
export function fieldMouseDown(
  step: OmnibarStep,
  clicks: number,
  button: OmnibarMouseButton,
  word: TextRange | null,
): void {
  const state = step.state;
  // The field and then its field editor report the same press.
  if (state.mouse?.pressed === true) return;
  const focusing = !hasFocus(state) || state.mouse != null;
  if (clicks === 1) state.doubleClickWord = null;
  const mouse: OmnibarMouse = {
    pressed: true,
    clickCount: clicks,
    button,
    selectAllOnRelease: focusing,
    wordAtPress: null,
    dragged: false,
  };
  if (
    !focusing &&
    button === "left" &&
    clicks === 1 &&
    state.phase === "focused" &&
    state.elided &&
    isAllSelected(step)
  ) {
    mouse.wordAtPress = word;
  }
  state.mouse = mouse;
  if (button === "right" && focusing && hasFocus(state) && !isComposing(state)) {
    acceptShownText(step);
    state.edit.selection = allOf(fieldText(state));
  }
}

/**
 * `OnMouseReleased`: select all after a focusing click that did not drag, whatever the field
 * editor selected; a focusing drag that selected nothing selects all too. Otherwise show the full
 * URL, keeping what the click or drag selected.
 */
export function fieldMouseUp(step: OmnibarStep): void {
  const state = step.state;
  const mouse = state.mouse;
  if (mouse == null) return;
  state.mouse = null;
  if (!hasFocus(state) || isComposing(state)) return;
  if (mouse.selectAllOnRelease && (!mouse.dragged || state.edit.selection.length === 0)) {
    acceptShownText(step);
    state.edit.selection = allOf(fieldText(state));
    return;
  }
  if (state.phase === "focused" && state.elided) {
    // A double-click unelides at its press; a single click or drag at its release.
    const offset = unelide(step, mouse.clickCount >= 2 ? "other" : "mouseRelease");
    const word = mouse.wordAtPress;
    if (offset != null && mouse.clickCount === 1 && word) {
      state.doubleClickWord = range(word.location + offset, word.length);
    }
  } else if (mouse.clickCount === 2 && state.doubleClickWord) {
    // crbug.com/40693090: the second press landed in the shifted text; select the first click's word.
    state.edit.selection = clamped(state.doubleClickWord, fieldText(state).length);
    state.doubleClickWord = null;
  }
}

// Keys

/** Cmd-A: the field editor's select-all. Never unelides. */
export function selectAll(step: OmnibarStep): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  acceptShownText(step);
  state.edit.selection = allOf(fieldText(state));
  state.lastEditKind = null;
}

/** Cmd-L while focused: leaves a keyword session, unelides and selects all. */
export function focusLocation(step: OmnibarStep): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  leaveKeyword(step, true);
  state.elided = false;
  acceptShownText(step);
  state.edit.selection = allOf(fieldText(state));
  state.lastEditKind = null;
}

/** Home: unelide even from select-all and go to the start of the full URL. */
export function home(step: OmnibarStep, extend: boolean): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state) || unelide(step, "home") == null) {
    step.handled = false;
    return;
  }
  state.edit.selection = extend ? range(0, upperBound(state.edit.selection)) : range(0, 0);
}

// Elision

/**
 * `UnapplySteadyStateElisions`: shows the full URL and maps the selection into it. Returns the
 * offset of the elided text inside the full URL, or null when nothing changed.
 */
export function unelide(step: OmnibarStep, gesture: OmnibarUnelision): number | null {
  const state = step.state;
  if (state.phase !== "focused" || !state.elided) return null;
  const shown = fieldText(state);
  const selection = clamped(state.edit.selection, shown.length);
  // "If everything is selected, the user likely does not intend to edit the URL." Home is the exception.
  if (isAllSelected(step) && gesture !== "home") return null;
  state.elided = false;
  const full = permanentText(state);
  let found = shown ? full.indexOf(shown) : -1;
  // "https://foobar" elides to "foobar/"; search without the slash.
  if (found < 0 && shown.length > 1 && shown.endsWith("/")) found = full.indexOf(shown.slice(0, -1));
  if (found < 0) {
    state.edit.selection = clamped(selection, full.length);
    return 0;
  }
  let start = selection.location;
  let end = upperBound(selection);
  const selected = shown.slice(selection.location, end);
  if (selection.length > 0 && gesture === "mouseRelease" && !classifiesAsSearch(step, selected)) {
    // A URL-like drag from the start keeps the scheme in the selection.
    if (start !== 0) start += found;
    if (end !== 0) end += found;
  } else {
    start += found;
    end += found;
  }
  state.edit.selection = clamped(range(start, end - start), full.length);
  return found;
}

/** Chromium `IsSelectAll`. */
export function isAllSelected(step: OmnibarStep): boolean {
  const text = fieldText(step.state);
  return text !== "" && rangesEqual(clamped(step.state.edit.selection, text.length), allOf(text));
}

function classifiesAsSearch(step: OmnibarStep, text: string): boolean {
  return step.resolver.destination(text)?.kind === "search";
}

/** Turns an inline completion or an arrowed row's text into typed text. */
export function acceptShownText(step: OmnibarStep): void {
  const state = step.state;
  if (state.phase !== "editing") return;
  if (arrowedRow(state)) {
    state.edit.userText = fieldText(state);
    state.edit.inlineCompletion = "";
    state.edit.suppressCompletion = true;
    refreshSuggestions(step);
  } else if (state.edit.inlineCompletion !== "") {
    state.edit.userText += state.edit.inlineCompletion;
    state.edit.inlineCompletion = "";
    state.edit.suppressCompletion = true;
  }
}
