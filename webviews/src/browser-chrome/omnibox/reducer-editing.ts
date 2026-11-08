// Field editor changes: typing, deletion, paste, IME composition, caret and selection moves, and
// undo (OmnibarReducer+Editing.swift).
import { beginFocus, closePopup, refreshSuggestions, UNDO_LIMIT } from "./reducer";
import type { OmnibarStep } from "./reducer";
import { startKeywordIfTyped } from "./reducer-keyword";
import { unelide } from "./reducer-selection";
import { clamped, singleLine } from "./rules";
import {
  canElide,
  completionRange,
  displayText,
  emptyEdit,
  fieldText,
  hasFocus,
  isComposing,
  visibleUserText,
} from "./state";
import type { OmnibarUndoEntry } from "./state";
import { caretAtEnd, characterCount, dropCharacters, rangesEqual } from "./text";
import type { OmnibarEditKind, OmnibarField } from "./types";

export function fieldChanged(step: OmnibarStep, field: OmnibarField, kind: OmnibarEditKind | null): void {
  const state = step.state;
  const marked = field.marked ?? null;
  const textChanged = field.text !== fieldText(state);
  const unchanged =
    !textChanged && rangesEqual(field.selection, state.edit.selection) && rangesEqual(marked, state.edit.marked);
  if (unchanged && hasFocus(state)) return;
  if (!hasFocus(state)) {
    // The field editor outlived editing: only a real edit starts editing again. A selection
    // report is not one: AppKit reloads the field's old text when it becomes first responder.
    if (!textChanged || kind == null) return;
    beginFocus(step, "programmatic");
  }
  // A selection report never changes the text: when its text differs, the field editor reloaded
  // the resting text. That is no edit; the presentation writes the state's text back.
  if (textChanged && kind == null && marked == null && !isComposing(state)) return;
  if (field.text !== fieldText(state) || kind != null || (!rangesEqual(marked, state.edit.marked) && marked != null)) {
    edit(step, field, kind ?? "insert");
  } else {
    selectionChanged(step, field);
  }
}

// Text

function edit(step: OmnibarStep, field: OmnibarField, kind: OmnibarEditKind): void {
  const state = step.state;
  // An edit is user input: nothing left to unelide or remember.
  if (state.mouse?.pressed === false) state.mouse = null;
  state.doubleClickWord = null;
  applyEdit(step, field, kind);
  state.elided = false;
}

function applyEdit(step: OmnibarStep, field: OmnibarField, kind: OmnibarEditKind): void {
  const state = step.state;
  const wasComposing = isComposing(state);
  if (field.marked) {
    // IME composition: record it, never complete, never write.
    if (!wasComposing) pushUndo(step);
    state.lastEditKind = null;
    state.phase = "editing";
    const length = field.text.length;
    state.edit = emptyEdit({
      userText: field.text,
      selection: clamped(field.selection, length),
      marked: clamped(field.marked, length),
      suppressCompletion: true,
    });
    refreshSuggestions(step);
    return;
  }

  const text = kind === "paste" ? singleLine(field.text) : field.text;
  if (!wasComposing && (kind !== state.lastEditKind || kind === "paste")) pushUndo(step);
  state.lastEditKind = kind === "paste" ? null : kind;
  const previous = state.edit.userText + state.edit.inlineCompletion;
  const hadCompletion = state.edit.inlineCompletion !== "" && state.phase === "editing";
  const selection = clamped(field.selection, text.length);
  const atEnd = rangesEqual(selection, caretAtEnd(text));
  state.phase = "editing";
  state.edit = emptyEdit({ userText: text, selection, suppressCompletion: kind !== "insert" || !atEnd });
  if (kind === "paste") state.editHasPaste = true;
  else if (text === "") state.editHasPaste = false;

  // Typing the next characters of a shown completion keeps the rest of it until fresh rows arrive.
  const typedCount = characterCount(text);
  if (
    hadCompletion &&
    kind === "insert" &&
    atEnd &&
    !wasComposing &&
    characterCount(previous) > typedCount &&
    previous.toLowerCase().startsWith(text.toLowerCase())
  ) {
    state.edit.inlineCompletion = dropCharacters(previous, typedCount);
    state.edit.selection = completionRange(state);
  }
  if (startKeywordIfTyped(step, text, kind)) return;
  refreshSuggestions(step);
}

/** Pushes the text as it is now onto the undo stack. */
export function pushUndo(step: OmnibarStep): void {
  const state = step.state;
  if (!hasFocus(state)) return;
  const entry = currentUndoEntry(step);
  const last = state.undo[state.undo.length - 1];
  if (!last || !undoEntriesEqual(last, entry)) state.undo.push(entry);
  if (state.undo.length > UNDO_LIMIT) state.undo.shift();
  state.redo = [];
}

function undoEntriesEqual(a: OmnibarUndoEntry, b: OmnibarUndoEntry): boolean {
  return a.text === b.text && a.untouched === b.untouched && rangesEqual(a.selection, b.selection);
}

function currentUndoEntry(step: OmnibarStep): OmnibarUndoEntry {
  const state = step.state;
  const text = state.phase === "focused" ? fieldText(state) : visibleUserText(state);
  return { text, selection: clamped(state.edit.selection, text.length), untouched: state.phase === "focused" };
}

// Selection

function selectionChanged(step: OmnibarStep, field: OmnibarField): void {
  const state = step.state;
  const marked = field.marked ?? null;
  if (rangesEqual(field.selection, state.edit.selection) && rangesEqual(marked, state.edit.marked)) return;
  state.lastEditKind = null;
  if (state.phase === "focused") {
    state.edit.selection = clamped(field.selection, fieldText(state).length);
    state.edit.marked = null;
    // A keystroke or caret move unelides; a press defers it to the release.
    if (state.mouse == null) unelide(step, "other");
    return;
  }
  const compositionEnded = isComposing(state) && marked == null;
  state.edit.marked = marked;
  let requery = compositionEnded;
  const { selected, rows } = state.popup;
  if (selected != null && selected > 0 && selected < rows.length) {
    // Moving the caret in an arrowed row's text makes it the typed text.
    state.edit.userText = fieldText(state);
    state.edit.inlineCompletion = "";
    state.edit.suppressCompletion = true;
    requery = true;
  } else if (state.edit.inlineCompletion !== "" && !rangesEqual(field.selection, completionRange(state))) {
    // Any caret move accepts the inline completion as typed text.
    state.edit.userText += state.edit.inlineCompletion;
    state.edit.inlineCompletion = "";
    state.edit.suppressCompletion = true;
  }
  const text = fieldText(state);
  state.edit.selection = clamped(field.selection, text.length);
  if (compositionEnded) state.edit.suppressCompletion = !rangesEqual(state.edit.selection, caretAtEnd(text));
  if (requery) refreshSuggestions(step);
}

// Undo

export function undo(step: OmnibarStep, isRedo: boolean): void {
  const state = step.state;
  if (!hasFocus(state) || isComposing(state)) {
    step.handled = false;
    return;
  }
  const entry = isRedo ? state.redo.pop() : state.undo.pop();
  if (!entry) return;
  const current = currentUndoEntry(step);
  if (isRedo) state.undo.push(current);
  else state.redo.push(current);
  state.lastEditKind = null;
  if (entry.untouched) {
    state.phase = "focused";
    state.elided = canElide(state) && entry.text === displayText(state);
    state.edit = emptyEdit({ selection: clamped(entry.selection, fieldText(state).length) });
    closePopup(step);
    step.effects.push({ type: "cancelQuery" });
  } else {
    state.phase = "editing";
    state.edit = emptyEdit({
      userText: entry.text,
      selection: clamped(entry.selection, entry.text.length),
      suppressCompletion: true,
    });
    refreshSuggestions(step);
  }
}
