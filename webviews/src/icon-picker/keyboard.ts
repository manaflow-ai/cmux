// Picker keys, as data. Focus stays in the search field; these keys drive the grid. Ctrl-N/J
// move down and Ctrl-P/K move up (the palette's list keys); arrows move in the grid; Return picks;
// Escape cancels; Ctrl-Tab and Ctrl-Shift-Tab change the tab. Cmd chords are never read here
// (the app's key dispatcher owns them, react-pages.md 1.2).
import type { GridMove } from "./gridModel";

export type PickerKeyAction =
  | { readonly kind: "move"; readonly move: GridMove }
  | { readonly kind: "pick" }
  | { readonly kind: "cancel" }
  | { readonly kind: "tab"; readonly step: 1 | -1 }
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
  if (event.isComposing || event.metaKey) return null;
  if (event.ctrlKey && !event.altKey) {
    if (event.key === "Tab") return { kind: "tab", step: event.shiftKey ? -1 : 1 };
    const move = CTRL_MOVES[event.key.toLowerCase()];
    return move && !event.shiftKey ? { kind: "move", move } : null;
  }
  if (event.altKey || event.ctrlKey) return null;
  if (event.key === "Enter") return { kind: "pick" };
  if (event.key === "Escape") return { kind: "cancel" };
  const move = PLAIN_MOVES[event.key];
  return move && !event.shiftKey ? { kind: "move", move } : null;
}
