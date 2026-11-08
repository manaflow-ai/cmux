// Keyword sessions (OmnibarReducer+Keyword.swift). The keyword and a typed space, or Tab after the
// exact keyword, start a session; the field then holds only the text after the keyword and every
// change goes to the extension. Enter hands the text over; Backspace at the start, Escape and
// blur end the session.
import { exactKeyword, keywordsEqual, matchKeyword } from "./keyword";
import { closePopup, commit, endSession, query } from "./reducer";
import type { OmnibarStep } from "./reducer";
import { fillText } from "./rules";
import { engineSiteURL, keywordForEngine, searchURL } from "./search-engine";
import { arrowedRow, emptyEdit, fieldText, hasFocus, isComposing } from "./state";
import type { OmnibarKeywordEntry } from "./state";
import { caretAtEnd, range, rangesEqual, trimSpaces } from "./text";
import type { OmnibarDisposition, OmnibarEditKind, OmnibarKeyword } from "./types";

/** Starts a session when an insert made the text "<keyword> ...". True when it did. */
export function startKeywordIfTyped(step: OmnibarStep, text: string, kind: OmnibarEditKind): boolean {
  const state = step.state;
  if (state.keyword != null || kind !== "insert" || isComposing(state)) return false;
  if (!rangesEqual(state.edit.selection, caretAtEnd(text))) return false;
  const match = matchKeyword(text, step.resolver.keywords);
  if (!match) return false;
  startKeyword(step, match.keyword, match.rest, "space");
  return true;
}

/** Tab after the exact keyword ("Press Tab to search"). */
export function startKeywordOnTab(step: OmnibarStep): boolean {
  const state = step.state;
  if (state.keyword != null || state.phase !== "editing" || isComposing(state)) return false;
  if ((state.popup.selected ?? 0) !== 0) return false;
  // The typed keyword, or a search engine's site its inline completion shows.
  const keywords = step.resolver.keywords;
  const keyword =
    exactKeyword(state.edit.userText, keywords) ??
    exactKeyword(
      fieldText(state),
      keywords.filter((k) => k.searchEngine != null),
    );
  if (!keyword) return false;
  startKeyword(step, keyword, "", "tab");
  return true;
}

export function startKeyword(
  step: OmnibarStep,
  keyword: OmnibarKeyword,
  text: string,
  entry: OmnibarKeywordEntry,
): void {
  const state = step.state;
  state.keyword = keyword;
  state.keywordEntry = entry;
  state.phase = "editing";
  state.elided = false;
  state.edit = emptyEdit({ userText: text, selection: caretAtEnd(text), suppressCompletion: true });
  state.undo = [];
  state.redo = [];
  state.lastEditKind = null;
  closePopup(step);
  if (keyword.searchEngine == null) step.effects.push({ type: "keywordStarted", extensionID: keyword.extensionID });
  query(step);
}

/**
 * Ends the session without Enter. `restoreText` puts back what Chromium's `ClearKeyword` does: the
 * keyword alone right after a Tab entry with nothing typed; nothing after a shortcut entry; else
 * the keyword and a space, so typing on does not start the session again.
 */
export function leaveKeyword(step: OmnibarStep, restoreText: boolean): void {
  const state = step.state;
  const keyword = state.keyword;
  if (keyword == null) return;
  state.keyword = null;
  if (keyword.searchEngine == null) step.effects.push({ type: "keywordEnded", extensionID: keyword.extensionID });
  closePopup(step);
  state.generation += 1;
  step.effects.push({ type: "cancelQuery" });
  if (!restoreText) return;
  let prefix: string;
  if (state.keywordEntry === "shortcut") prefix = "";
  else if (state.keywordEntry === "tab" && state.edit.userText === "") prefix = keyword.keyword;
  else prefix = `${keyword.keyword} `;
  const text = prefix + state.edit.userText;
  state.edit = emptyEdit({ userText: text, selection: range(prefix.length, 0), suppressCompletion: true });
  query(step);
}

/** Opt-Cmd-F: an empty session of the default search engine. */
export function searchWithDefaultEngine(step: OmnibarStep): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const engine = step.resolver.searchEngine;
  const keyword = step.resolver.keywords.find((k) => k.searchEngine?.id === engine.id) ?? keywordForEngine(engine);
  if (keywordsEqual(state.keyword, keyword) && state.edit.userText === "") return;
  leaveKeyword(step, false);
  startKeyword(step, keyword, "", "shortcut");
}

/** Backspace at the start of a session's text leaves the session. */
export function backspaceAtStart(step: OmnibarStep): void {
  const state = step.state;
  if (
    state.keyword == null ||
    !hasFocus(state) ||
    isComposing(state) ||
    !rangesEqual(state.edit.selection, range(0, 0))
  ) {
    step.handled = false;
    return;
  }
  leaveKeyword(step, true);
}

/** The session's text changed: the extension gets it (also when empty). */
export function keywordQuery(step: OmnibarStep, keyword: OmnibarKeyword): void {
  const state = step.state;
  state.generation += 1;
  // A search engine session has no rows: Enter searches with the engine.
  if (keyword.searchEngine != null) {
    closePopup(step);
    step.effects.push({ type: "cancelQuery" });
    return;
  }
  step.effects.push({
    type: "keywordInput",
    extensionID: keyword.extensionID,
    text: state.edit.userText,
    generation: state.generation,
  });
}

/** Enter or a row click in a session: the extension (or the engine) gets `text`. */
export function commitKeyword(step: OmnibarStep, text: string, disposition: OmnibarDisposition): void {
  const state = step.state;
  const keyword = state.keyword;
  if (keyword == null) return;
  const engine = keyword.searchEngine;
  if (engine != null) {
    // Enter in a search engine session searches there; with no text it opens the engine's site.
    state.keyword = null;
    const queryText = trimSpaces(text);
    const url = searchURL(engine, queryText) ?? (queryText === "" ? engineSiteURL(engine) : null);
    if (url == null) {
      state.keyword = keyword;
      step.effects.push({ type: "beep" });
      return;
    }
    return commit(step, url, disposition);
  }
  state.keyword = null;
  state.phase = "committing";
  state.committingDisplay = state.pageURL;
  state.retainedText = null;
  endSession(step);
  step.effects.push({ type: "cancelQuery" });
  step.effects.push({
    type: "ended",
    reason: { kind: "keyword", extensionID: keyword.extensionID, text, disposition },
  });
}

/** What Enter sends: the arrowed row's content, else the typed text. */
export function keywordCommitText(step: OmnibarStep): string {
  const row = arrowedRow(step.state);
  return row ? fillText(row) : step.state.edit.userText;
}
