// Keys, the suggestion rows (keyboard and mouse), and async results (OmnibarReducer+Popup.swift).
import { closePopup, commit, commitDestination, endSession } from "./reducer";
import type { OmnibarStep } from "./reducer";
import { pushUndo, undo } from "./reducer-editing";
import {
  backspaceAtStart,
  commitKeyword,
  keywordCommitText,
  leaveKeyword,
  searchWithDefaultEngine,
  startKeywordOnTab,
} from "./reducer-keyword";
import { chosenRow, switchToTab, typedDestination, typoFixedDestination } from "./reducer-rows";
import { focusLocation, home, selectAll } from "./reducer-selection";
import { desiredTLDURL, fillText, inlineCompletion, isHTTPSUpgrade } from "./rules";
import { canElide, completionRange, emptyEdit, fieldText, hasFocus, isComposing, isPopupOpen } from "./state";
import { allOf, caretAtEnd, rangesEqual } from "./text";
import type { BrowserSuggestion, OmnibarDisposition, OmnibarKey, OmnibarPoint, ShownRow } from "./types";
import { urlScheme } from "./url-display";

export function key(step: OmnibarStep, pressed: OmnibarKey): void {
  // A focus from a click whose press never came: keys end it.
  if (step.state.mouse?.pressed === false) step.state.mouse = null;
  switch (pressed.kind) {
    case "up":
      return move(step, -1, true);
    case "down":
      return move(step, 1, true);
    case "tab":
      if (!startKeywordOnTab(step)) move(step, 1, false);
      return;
    case "backTab":
      return move(step, -1, false);
    case "enter":
      return enter(step, pressed.disposition);
    case "enterAddingTLD":
      return enterAddingTLD(step, pressed.disposition);
    case "escape":
      return escape(step);
    case "selectAll":
      return selectAll(step);
    case "focusLocation":
      return focusLocation(step);
    case "home":
      return home(step, pressed.extend);
    case "deleteSuggestion":
      return deleteSuggestion(step);
    case "undo":
      return undo(step, false);
    case "redo":
      return undo(step, true);
    case "backspaceAtStart":
      return backspaceAtStart(step);
    case "searchWithDefaultEngine":
      return searchWithDefaultEngine(step);
  }
}

/** Up/Down clamp at both ends. Tab/Shift-Tab past either end are not handled, so focus leaves. */
function move(step: OmnibarStep, delta: number, clamp: boolean): void {
  const state = step.state;
  if (!isPopupOpen(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const rows = state.popup.rows;
  const next = (state.popup.selected ?? 0) + delta;
  if (!(next >= 0 && next < rows.length) && !clamp) {
    step.handled = false;
    return;
  }
  select(step, Math.min(Math.max(next, 0), rows.length - 1));
}

/** The keyboard highlight moves to `row`; the field shows its text. */
export function select(step: OmnibarStep, row: number): void {
  const state = step.state;
  state.popup.selected = row;
  state.popup.hover = null;
  state.popup.source = "keyboard";
  state.lastEditKind = null;
  if (row > 0) state.edit.selection = caretAtEnd(fieldText(state));
  else if (state.edit.inlineCompletion === "") state.edit.selection = caretAtEnd(state.edit.userText);
  else state.edit.selection = completionRange(state);
}

function enter(step: OmnibarStep, disposition: OmnibarDisposition): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    // No focus: the field editor outlived editing; IME: the input method commits the composition.
    step.handled = false;
    return;
  }
  if (state.keyword != null) return commitKeyword(step, keywordCommitText(step), disposition);
  const row = chosenRow(step);
  if (row?.kind === "switchToTab" && row.tabKey != null) return switchToTab(step, row, row.tabKey, disposition);
  if (row?.kind === "answer") {
    step.effects.push({ type: "copyAnswer", text: row.content ?? row.title });
    return;
  }
  const fixed = typoFixedDestination(step);
  if (fixed) {
    step.effects.push({ type: "hostTypoFixed", typedHost: fixed.typedHost });
    step.effects.push({ type: "typedNavigation", url: fixed.url });
    noteHTTPSUpgrade(step, fixed.url, disposition);
    return commit(step, fixed.url, disposition);
  }
  const destination = commitDestination(step);
  if (destination == null) {
    step.effects.push({ type: "beep" });
    return;
  }
  const typed = typedDestination(step);
  if (typed != null && typed === destination) {
    step.effects.push({ type: "typedNavigation", url: typed });
    if (isHTTPSUpgrade(fieldText(state), typed, (text) => step.resolver.url(text))) {
      noteHTTPSUpgrade(step, typed, disposition);
    }
  }
  commit(step, destination, disposition);
}

/** A typed https upgrade loading in this tab may fall back to http. */
function noteHTTPSUpgrade(step: OmnibarStep, url: string, disposition: OmnibarDisposition): void {
  if (disposition !== "currentTab" || urlScheme(url) !== "https") return;
  step.effects.push({ type: "typedHTTPSUpgrade", url });
}

/**
 * Control-Enter: the typed host without a dot gets `www.` and `.com`, keeping its path. Anything
 * else, an arrowed row or a keyword session commits as Enter does.
 */
function enterAddingTLD(step: OmnibarStep, disposition: OmnibarDisposition): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const arrowed = (state.popup.selected ?? 0) > 0;
  const url =
    state.keyword == null && state.phase === "editing" && !arrowed
      ? desiredTLDURL(state.edit.userText, (text) => step.resolver.url(text))
      : null;
  if (url == null) return enter(step, disposition);
  step.effects.push({ type: "typedNavigation", url });
  noteHTTPSUpgrade(step, url, disposition);
  commit(step, url, disposition);
}

/**
 * Chromium `OnEscapeKeyPressed`, one step per press: an arrowed row reverts to the typed text;
 * else an open card closes; else the text reverts to the page URL, and when the user had not
 * typed, focus returns to the page in the same press.
 */
function escape(step: OmnibarStep): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const selected = state.popup.selected;
  if (state.phase === "editing" && selected != null && selected > 0 && selected < state.popup.rows.length) {
    select(step, 0);
    return;
  }
  if (isPopupOpen(state)) {
    closePopup(step);
    // Results of the query in flight must not reopen the card.
    state.generation += 1;
    step.effects.push({ type: "cancelQuery" });
    return;
  }
  leaveKeyword(step, false);
  const wasEditing = state.phase === "editing";
  if (wasEditing) pushUndo(step);
  state.editHasPaste = false;
  state.phase = "focused";
  state.elided = canElide(state);
  state.edit = emptyEdit({ selection: allOf(fieldText(state)) });
  state.lastEditKind = null;
  closePopup(step);
  step.effects.push({ type: "cancelQuery" });
  if (!wasEditing) {
    state.phase = "idle";
    endSession(step);
    step.effects.push({ type: "ended", reason: { kind: "cancel" } });
  }
}

/** Shift-Delete on the keyboard-selected history row; otherwise the field deletes forward. */
function deleteSuggestion(step: OmnibarStep): void {
  const state = step.state;
  const line = state.popup.selected;
  const rows = state.popup.rows;
  if (
    !isPopupOpen(state) ||
    isComposing(state) ||
    line == null ||
    line >= rows.length ||
    rows[line].kind !== "history"
  ) {
    step.handled = false;
    return;
  }
  const url = rows[line].url;
  rows.splice(line, 1);
  // The query in flight may still return the deleted row.
  state.generation += 1;
  step.effects.push({ type: "cancelQuery" });
  step.effects.push({ type: "deleteSuggestion", url });
  if (line === 0) state.edit.inlineCompletion = "";
  if (rows.length === 0) {
    closePopup(step);
    state.edit.selection = caretAtEnd(state.edit.userText);
    return;
  }
  select(step, Math.min(line, rows.length - 1));
}

// Results

export function suggestionsArrived(
  step: OmnibarStep,
  incoming: readonly BrowserSuggestion[],
  generation: number,
): void {
  const state = step.state;
  // Only the latest query counts; anything else is stale.
  if (generation !== state.generation || state.phase !== "editing") return;
  const popup = state.popup;
  const selected = popup.selected;
  if (selected != null && selected > 0 && selected < popup.rows.length) {
    // The user is arrowing: keep their row, or the rows they are looking at when it is gone.
    const chosen = popup.rows[selected];
    const index = incoming.findIndex((row) => row.url === chosen.url);
    if (index <= 0) return;
    popup.rows = [...incoming];
    popup.selected = index;
    popup.stale = false;
    return;
  }
  const rows = [...incoming];
  const text = state.edit.userText;
  const atEnd =
    rangesEqual(state.edit.selection, caretAtEnd(text)) ||
    (state.edit.inlineCompletion !== "" && rangesEqual(state.edit.selection, completionRange(state)));
  const mayComplete = !isComposing(state) && !state.edit.suppressCompletion && atEnd;
  state.edit.inlineCompletion = "";
  let completion: string | null = null;
  if (mayComplete) {
    for (let index = 0; index < rows.length; index++) {
      completion = inlineCompletion(rows[index], text, state.home);
      if (completion == null) continue;
      // The completed row becomes the default match.
      rows.unshift(...rows.splice(index, 1));
      break;
    }
  }
  if (completion != null) {
    state.edit.inlineCompletion = completion;
    state.edit.selection = completionRange(state);
  } else if (mayComplete) {
    state.edit.selection = caretAtEnd(text);
  }
  if (rows.length === 0) {
    closePopup(step);
    return;
  }
  const wasOpen = popup.rows.length > 0;
  popup.rows = rows;
  popup.selected = 0;
  popup.hover = null;
  popup.source = "keyboard";
  popup.stale = false;
  if (!wasOpen) popup.pointer = null;
}

// Mouse over rows

function clickedIndex(rows: readonly BrowserSuggestion[], row: number, shown: ShownRow): number {
  const same = (candidate: BrowserSuggestion | undefined) =>
    candidate != null && candidate.kind === shown.kind && candidate.url === shown.url;
  if (same(rows[row])) return row;
  return rows.findIndex(same);
}

/** Hover highlights a row only after the pointer actually moved. */
export function rowHover(step: OmnibarStep, row: number | null, pointer: OmnibarPoint): void {
  const state = step.state;
  const last = state.popup.pointer;
  if (!isPopupOpen(state) || (last != null && last.x === pointer.x && last.y === pointer.y)) return;
  state.popup.pointer = { ...pointer };
  if (last == null) return;
  if (row != null && row >= 0 && row < state.popup.rows.length) {
    state.popup.hover = row;
    state.popup.source = "mouse";
  } else {
    state.popup.hover = null;
  }
}

export function rowClick(
  step: OmnibarStep,
  row: number,
  disposition: OmnibarDisposition,
  shown?: ShownRow | null,
): void {
  const state = step.state;
  // The click names the row the card drew; rows that replaced them in the same push keep it at
  // its new index, or drop the click. Never the row that now sits where it was.
  const index = shown == null ? row : clickedIndex(state.popup.rows, row, shown);
  // The view commits marked text first; never commit around the IME.
  if (!isPopupOpen(state) || index < 0 || index >= state.popup.rows.length || isComposing(state)) {
    step.handled = false;
    return;
  }
  const chosen = state.popup.rows[index];
  if (state.keyword != null) return commitKeyword(step, fillText(chosen), disposition);
  if (chosen.kind === "switchToTab" && chosen.tabKey != null)
    return switchToTab(step, chosen, chosen.tabKey, disposition);
  if (chosen.kind === "answer") {
    step.effects.push({ type: "copyAnswer", text: chosen.content ?? chosen.title });
    return;
  }
  commit(step, chosen.url, disposition);
}
