// The omnibar field editor's keys, as the native OmnibarFieldEditor and the AddressBarView text
// field delegate map them (`doCommandBy` selectors, Return with modifiers, Shift-Delete, undo).
// Pure: a DOM keydown becomes one `OmnibarKey`, or null for the input's own default.
import type { OmnibarDisposition, OmnibarEditKind, OmnibarKey } from "../omnibox/types";

export type KeyModifiers = { meta: boolean; shift: boolean; alt: boolean; ctrl?: boolean };

/** The parts of a KeyboardEvent the mapping reads. */
export type KeyPress = KeyModifiers & { key: string; ctrl: boolean };

export type KeyContext = {
  /** The suggestion card is open (Ctrl-N/P/J/K move its selection). */
  popupOpen: boolean;
  /** The field's selection is the caret at the start (Backspace there leaves a keyword session). */
  caretAtStart: boolean;
};

/** Cmd: background tab; Shift-Cmd or Option: foreground tab; Shift: new window (`Disposition(flags)`). */
export function dispositionFor(modifiers: KeyModifiers): OmnibarDisposition {
  if (modifiers.meta) return modifiers.shift ? "newForegroundTab" : "newBackgroundTab";
  if (modifiers.alt) return "newForegroundTab";
  if (modifiers.shift) return "newWindow";
  return "currentTab";
}

/** The key the omnibar may take for `press`; null leaves it to the input. */
export function omnibarKeyFor(press: KeyPress, context: KeyContext): OmnibarKey | null {
  const { meta, shift, alt, ctrl } = press;
  const plain = !meta && !alt && !ctrl;
  switch (press.key) {
    case "Enter": {
      const disposition = dispositionFor(press);
      return ctrl ? { kind: "enterAddingTLD", disposition } : { kind: "enter", disposition };
    }
    case "ArrowDown":
      return plain && !shift ? { kind: "down" } : null;
    case "ArrowUp":
      return plain && !shift ? { kind: "up" } : null;
    case "Tab":
      if (!plain) return null;
      return shift ? { kind: "backTab" } : { kind: "tab" };
    case "Escape":
      return plain && !shift ? { kind: "escape" } : null;
    case "Home":
      // The Home key (Shift-Home extends); Cmd-Left is a caret move the input makes.
      return plain ? { kind: "home", extend: shift } : null;
    case "Delete":
      // Shift with forward delete removes the highlighted history row.
      return plain && shift ? { kind: "deleteSuggestion" } : null;
    case "Backspace":
      return plain && !shift && context.caretAtStart ? { kind: "backspaceAtStart" } : null;
  }
  const letter = press.key.length === 1 ? press.key.toLowerCase() : "";
  if (meta && !alt && !ctrl) {
    if (letter === "a" && !shift) return { kind: "selectAll" };
    if (letter === "z") return shift ? { kind: "redo" } : { kind: "undo" };
  }
  // Ctrl-N/P (and J/K) move the open list, as Down and Up do.
  if (ctrl && !meta && !alt && !shift && context.popupOpen) {
    if (letter === "n" || letter === "j") return { kind: "down" };
    if (letter === "p" || letter === "k") return { kind: "up" };
  }
  return null;
}

/** A read-only bar (a sign-in window) takes only the keys that select or leave. */
export function admitsKey(key: OmnibarKey, readOnly: boolean): boolean {
  if (!readOnly) return true;
  return key.kind === "escape" || key.kind === "selectAll" || key.kind === "focusLocation" || key.kind === "home";
}

/** The kind of an edit from `InputEvent.inputType` (the field editor's `shouldChangeText`). */
export function editKindFor(inputType: string): OmnibarEditKind {
  if (inputType.startsWith("insertFromPaste")) return "paste";
  if (inputType.startsWith("delete")) return "delete";
  return "insert";
}
