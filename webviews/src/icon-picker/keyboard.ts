// Picker keys, as data. Focus stays in the search field; these keys drive the grid. Ctrl-N/J
// move down and Ctrl-P/K move up (the palette's list keys); arrows move in the grid; Return picks;
// Escape steps back (clears the search, then the category, then cancels); Ctrl-Tab and
// Ctrl-Shift-Tab step through the categories; Alt-Down and Alt-Up jump between sections; Cmd-K
// opens the Actions menu. Cmd-K is the picker panel's own key (the panel is a floating key
// window with no app command on it); every other Cmd chord is left to the app's key dispatcher
// (react-pages.md 1.2).
import type { GridMove } from "./gridModel";

export type PickerKeyAction =
  | { readonly kind: "move"; readonly move: GridMove }
  | { readonly kind: "pick" }
  | { readonly kind: "back" }
  | { readonly kind: "actions" }
  | { readonly kind: "category"; readonly step: 1 | -1 }
  | { readonly kind: "section"; readonly step: 1 | -1 };

export interface KeyLike {
  readonly key: string;
  readonly ctrlKey: boolean;
  readonly metaKey: boolean;
  readonly altKey: boolean;
  readonly shiftKey: boolean;
  readonly isComposing?: boolean;
}

const CTRL_MOVES: Record<string, GridMove> = { n: "down", j: "down", p: "up", k: "up" };
const PLAIN_MOVES: Record<string, GridMove> = {
  ArrowDown: "down",
  ArrowUp: "up",
  ArrowLeft: "left",
  ArrowRight: "right",
  PageDown: "pageDown",
  PageUp: "pageUp",
};

/** The picker action for a key, or null to leave the key to the field (typing, IME). */
export function pickerKeyAction(event: KeyLike): PickerKeyAction | null {
  // An IME composition (Japanese input) owns Return, arrows and Escape until it commits.
  if (event.isComposing) return null;
  if (event.metaKey) {
    const plain = !event.ctrlKey && !event.altKey && !event.shiftKey;
    return plain && event.key.toLowerCase() === "k" ? { kind: "actions" } : null;
  }
  if (event.ctrlKey && !event.altKey) {
    if (event.key === "Tab") return { kind: "category", step: event.shiftKey ? -1 : 1 };
    const move = CTRL_MOVES[event.key.toLowerCase()];
    return move && !event.shiftKey ? { kind: "move", move } : null;
  }
  // Alt-Down and Alt-Up jump to the next or previous section.
  if (event.altKey && !event.ctrlKey && !event.shiftKey && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
    return { kind: "section", step: event.key === "ArrowDown" ? 1 : -1 };
  }
  if (event.altKey || event.ctrlKey) return null;
  if (event.key === "Enter") return { kind: "pick" };
  if (event.key === "Escape") return { kind: "back" };
  const move = PLAIN_MOVES[event.key];
  return move && !event.shiftKey ? { kind: "move", move } : null;
}

const SEGMENTER = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Whether a key types text (a key outside the search field sends it to the search). */
export function typesText(event: KeyLike): boolean {
  if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return false;
  // Key names ("Enter", "ArrowDown") are words; a typed key is one grapheme ("a", "ね", "👍").
  return [...SEGMENTER.segment(event.key)].length === 1;
}
