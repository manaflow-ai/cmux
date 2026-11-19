// Ctrl-N and Ctrl-P step a list as Down and Up do, in every composer menu and picker (the Emacs and
// macOS text-field convention, as drillKeys.ts and the @ and emoji lists already do). Lawrence,
// 2026-10-28: "this needs to work with keyboard shortcuts like up arrow ctrl n/p etc" and "clicking
// enter doesnt work".

export interface ListChordKey {
  key: string;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
}

/** The arrow a Ctrl-N or Ctrl-P stands for, or undefined for any other key. */
export function listChordArrow(event: ListChordKey): "ArrowDown" | "ArrowUp" | undefined {
  if (!event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return undefined;
  const key = event.key.toLowerCase();
  return key === "n" ? "ArrowDown" : key === "p" ? "ArrowUp" : undefined;
}

/** The step a list moves for a key: +1 for Down and Ctrl-N, -1 for Up and Ctrl-P, else 0. Plain
 * arrows only: a modified arrow moves or extends the text selection. */
export function listStep(event: ListChordKey): 1 | -1 | 0 {
  const plain = !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
  const key = plain ? event.key : listChordArrow(event);
  return key === "ArrowDown" ? 1 : key === "ArrowUp" ? -1 : 0;
}

interface ReplayableEvent extends ListChordKey {
  target: EventTarget | null;
  preventDefault(): void;
  stopPropagation(): void;
}

/**
 * Plays a Ctrl-N or Ctrl-P as the arrow it stands for, on the element that took the key, so a list
 * whose arrows belong to a library (Base UI's menus and comboboxes) steps the same way. Returns true
 * when it did; the chord itself goes no further (the text field's own Ctrl-N moves no caret).
 */
export function replayListChord(event: ReplayableEvent): boolean {
  const arrow = listChordArrow(event);
  const target = event.target as Element | null;
  if (!arrow || !target || typeof (target as Element).dispatchEvent !== "function") return false;
  event.preventDefault();
  event.stopPropagation();
  const View = target.ownerDocument?.defaultView?.KeyboardEvent ?? KeyboardEvent;
  target.dispatchEvent(new View("keydown", { key: arrow, code: arrow, bubbles: true, cancelable: true }));
  return true;
}
