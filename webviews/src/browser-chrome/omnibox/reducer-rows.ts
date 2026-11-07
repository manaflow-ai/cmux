// Rows that commit differently: Switch to Tab rows, the typed-URL mark of the default row, and
// late rows joining the card (OmnibarReducer+Rows.swift).
import { mergeSuggestions } from "./merge";
import { commit, endSession } from "./reducer";
import type { OmnibarStep } from "./reducer";
import { leaveKeyword } from "./reducer-keyword";
import { fieldText, highlightedRow } from "./state";
import type { BrowserSuggestion, OmnibarDisposition } from "./types";

/** The row Enter takes now: the keyboard selection, unless it is the default row of stale rows. */
export function chosenRow(step: OmnibarStep): BrowserSuggestion | null {
  const state = step.state;
  const { selected, rows, stale } = state.popup;
  if (state.phase !== "editing" || selected == null || selected >= rows.length || (selected === 0 && stale))
    return null;
  return rows[selected];
}

/** The URL Enter loads when it is the typed text itself (or its inline completion), else null. */
export function typedDestination(step: OmnibarStep): string | null {
  const state = step.state;
  if (state.phase !== "editing") return null;
  const row = chosenRow(step);
  if (row) {
    if (state.popup.selected !== 0 || !(row.kind === "navigate" || row.kind === "history" || row.kind === "bookmark")) {
      return null;
    }
    return row.url;
  }
  const destination = step.resolver.destination(fieldText(state));
  return destination?.kind === "url" ? destination.url : null;
}

/**
 * Where Enter goes when the typed text has a top-level-domain typo: only for the default row of
 * text the user typed (no paste, no inline completion, no arrowed or history row).
 */
export function typoFixedDestination(step: OmnibarStep): { url: string; typedHost: string } | null {
  const state = step.state;
  if (state.phase !== "editing" || state.keyword != null || state.editHasPaste || state.edit.inlineCompletion !== "") {
    return null;
  }
  const row = chosenRow(step);
  if (row && (state.popup.selected !== 0 || !(row.kind === "navigate" || row.kind === "search"))) return null;
  return step.resolver.typoFixedURL(state.edit.userText);
}

/** Phase B rows join the card: the selection, the hover and every row above them stay. */
export function moreSuggestionsArrived(
  step: OmnibarStep,
  rows: readonly BrowserSuggestion[],
  generation: number,
  capacity: number,
): void {
  const state = step.state;
  const popup = state.popup;
  if (generation !== state.generation || state.phase !== "editing" || state.keyword != null) return;
  if (popup.rows.length === 0 || popup.stale) return;
  const highlight = Math.max(highlightedRow(popup) ?? 0, popup.selected ?? 0);
  popup.rows = mergeSuggestions(popup.rows, highlight, rows, capacity);
}

/**
 * Enter or a click on a Switch to Tab row reveals that tab and leaves this omnibar as it was;
 * Shift (new window) loads the page here instead; the other new-tab chords open it as any row.
 */
export function switchToTab(
  step: OmnibarStep,
  row: BrowserSuggestion,
  key: string,
  disposition: OmnibarDisposition,
): void {
  switch (disposition) {
    case "currentTab":
      leaveKeyword(step, false);
      step.state.phase = "idle";
      step.state.retainedText = null;
      endSession(step);
      step.effects.push({ type: "cancelQuery" });
      step.effects.push({ type: "ended", reason: { kind: "switchToTab", key } });
      return;
    case "newWindow":
      return commit(step, row.url, "currentTab");
    case "newBackgroundTab":
    case "newForegroundTab":
      return commit(step, row.url, disposition);
  }
}
