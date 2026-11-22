// What a key does in a drill-down list's field (DrillList.tsx). Pure, so the app's palette picker
// can follow the same table (viewer-empty/pickerModel.ts re-exports it as `pickerKeyAction`).
// Widget keys only: Cmd and Ctrl chords are the app's (the native key dispatcher), except the two
// list chords below, which act only while the field has focus:
//   Cmd-Up      the parent folder (Finder's "enclosing folder");
//   Ctrl-N/P    next and previous row (Emacs and macOS text-field convention).

export type DrillAction =
  | { kind: "move"; delta: number }
  | { kind: "edge"; to: "first" | "last" }
  | { kind: "enter" }
  | { kind: "up" }
  | { kind: "choose" }
  | { kind: "clear" }
  | { kind: "cancel" }
  | null;

export interface DrillKey {
  key: string;
  shiftKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
}

export interface DrillKeyState {
  query: string;
  /** The field's selection (start and end). */
  caretStart: number;
  caretEnd: number;
  /** In right-to-left text the inline end is on the left: Left enters and Right goes up. */
  dir?: "ltr" | "rtl";
}

/** The chords a drill list handles itself; every other Cmd or Ctrl chord passes to the app. */
export const DRILL_WIDGET_CHORDS = ["Meta+ArrowUp", "Control+n", "Control+p"] as const;

/**
 * The action of a key. The inline-end arrow enters and the inline-start arrow goes up only from the
 * end and the start of the text, so they still move the caret inside a query.
 */
export function drillKeyAction(event: DrillKey, state: DrillKeyState): DrillAction {
  const plain = !event.metaKey && !event.altKey;
  const caretAtEnd = state.caretStart === state.query.length && state.caretEnd === state.caretStart;
  const caretAtStart = state.caretStart === 0 && state.caretEnd === 0;
  const forward = state.dir === "rtl" ? "ArrowLeft" : "ArrowRight";
  const back = state.dir === "rtl" ? "ArrowRight" : "ArrowLeft";
  switch (event.key) {
    case "ArrowDown":
      return plain ? { kind: "move", delta: 1 } : null;
    case "ArrowUp":
      if (event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey) return { kind: "up" };
      return plain ? { kind: "move", delta: -1 } : null;
    case "n":
      return event.ctrlKey && plain ? { kind: "move", delta: 1 } : null;
    case "p":
      return event.ctrlKey && plain ? { kind: "move", delta: -1 } : null;
    case "PageDown":
      return plain && !event.ctrlKey ? { kind: "move", delta: 10 } : null;
    case "PageUp":
      return plain && !event.ctrlKey ? { kind: "move", delta: -10 } : null;
    case "Home":
      return state.query === "" && plain && !event.ctrlKey ? { kind: "edge", to: "first" } : null;
    case "End":
      return state.query === "" && plain && !event.ctrlKey ? { kind: "edge", to: "last" } : null;
    case "Tab":
      return event.shiftKey || !plain || event.ctrlKey ? null : { kind: "enter" };
    case forward:
      return plain && !event.ctrlKey && !event.shiftKey && caretAtEnd ? { kind: "enter" } : null;
    case back:
      return plain && !event.ctrlKey && !event.shiftKey && caretAtStart ? { kind: "up" } : null;
    case "Backspace":
      return state.query === "" && plain && !event.ctrlKey ? { kind: "up" } : null;
    case "Enter":
      return plain && !event.ctrlKey ? { kind: "choose" } : null;
    case "Escape":
      return state.query === "" ? { kind: "cancel" } : { kind: "clear" };
    default:
      return null;
  }
}
