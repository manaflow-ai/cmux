// The page's global keys, isolated in one narrow effect. Anywhere: Cmd-K opens the palette,
// Option-Up/Down move through the list (Option-Shift: the next unread), Escape closes the
// palette, then the editor, then the sheet, then clears the current message. Outside a text field
// (the keys of an issue list): j/k move the current message, r replies to it, t opens its thread,
// c copies its link, e resolves or reopens the thread. The listener is attached once; it calls
// the latest actions through an Effect Event, so no ref is written during render.
import { useEffect, useEffectEvent } from "react";

export interface HomeKeyActions {
  openPalette(): void;
  move(delta: 1 | -1, unreadOnly: boolean): void;
  escape(): boolean;
  /** j / k. */
  step(delta: 1 | -1): void;
  reply(): void;
  thread(): void;
  copyLink(): void;
  resolve(): void;
}

const editable = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable || target.closest("input, textarea, select, [contenteditable='true']") !== null);

export function useHomeKeys(actions: HomeKeyActions): void {
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    if (event.defaultPrevented || event.isComposing) return;
    // A popup (menu, popover, picker, the palette) owns its own Escape and arrows.
    if (event.target instanceof Element && event.target.closest(".ui-popup, .lg-palette")) return;
    const key = event.key.toLowerCase();
    const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    if (key === "k" && event.metaKey && !event.shiftKey && !event.altKey) actions.openPalette();
    else if (event.altKey && !event.metaKey && (key === "arrowup" || key === "arrowdown"))
      actions.move(key === "arrowdown" ? 1 : -1, event.shiftKey);
    else if (key === "escape" && actions.escape()) {
      // handled
    } else if (plain && !editable(event.target) && (key === "j" || key === "k")) actions.step(key === "j" ? 1 : -1);
    else if (plain && !editable(event.target) && key === "r") actions.reply();
    else if (plain && !editable(event.target) && key === "t") actions.thread();
    else if (plain && !editable(event.target) && key === "c") actions.copyLink();
    else if (plain && !editable(event.target) && key === "e") actions.resolve();
    else return;
    event.preventDefault();
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => onKeyDown(event);
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, []);
}
