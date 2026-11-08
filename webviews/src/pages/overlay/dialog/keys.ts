// The dialog keyboard (CmuxDialogKeys in Swift, the same rules): Return presses the default button,
// Escape or Command-period the cancel button, Command plus a button's key that button, and Tab and
// Shift-Tab move the focus inside the card only.
import type { DialogKeys } from "./types";

export type KeyAction = { press: string } | { focus: "next" | "previous" } | null;

export interface KeyLike {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}

export function keyAction(event: KeyLike, keys: DialogKeys): KeyAction {
  const other = event.ctrlKey || event.altKey;
  switch (event.key) {
    case "Enter":
      return other || !keys.return ? null : { press: keys.return };
    case "Escape":
      return keys.escape ? { press: keys.escape } : null;
    case "Tab":
      return other || event.metaKey ? null : { focus: event.shiftKey ? "previous" : "next" };
    default: {
      if (!event.metaKey || other || event.key.length !== 1) return null;
      if (event.key === ".") return keys.escape ? { press: keys.escape } : null;
      const button = keys.command[event.key.toLowerCase()];
      return button ? { press: button } : null;
    }
  }
}

/** The control after (or before) `current` among `count`, wrapping; with none focused, the first (or last). */
export function focusAfter(current: number, count: number, backward: boolean): number {
  if (count === 0) return -1;
  if (current < 0 || current >= count) return backward ? count - 1 : 0;
  return backward ? (current + count - 1) % count : (current + 1) % count;
}
