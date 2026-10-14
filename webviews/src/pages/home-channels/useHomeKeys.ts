// The page's global keys, isolated in one narrow effect: Cmd-K opens the palette, Option-Up and
// Option-Down move through the conversation list, Option-Shift-Up/Down jump to the next unread
// conversation, Escape closes the palette, then the editor, then the thread. Outside a text field:
// J and K move the message cursor, R replies to the message under it, T opens or closes its
// thread, C copies its link and E resolves (or reopens) its thread. The listener is attached
// once; it calls the latest actions through an Effect Event, so no ref is written during render.
import { useEffect, useEffectEvent } from "react";

export interface HomeKeyActions {
  openSwitcher(): void;
  move(delta: 1 | -1, unreadOnly: boolean): void;
  escape(): boolean;
  cursor(delta: 1 | -1): void;
  reply(): void;
  toggleThread(): void;
  copyLink(): void;
  resolve(): void;
}

/** A field that takes typing: letter keys belong to it. */
function typing(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  if (target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']")) return true;
  return target instanceof HTMLElement && target.isContentEditable;
}

export function useHomeKeys(actions: HomeKeyActions): void {
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    if (event.defaultPrevented || event.isComposing) return;
    // A popup (menu, popover, picker) owns its own Escape and arrows.
    if (event.target instanceof Element && event.target.closest(".ui-popup")) return;
    const key = event.key.toLowerCase();
    const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    if (key === "k" && event.metaKey && !event.shiftKey && !event.altKey) {
      actions.openSwitcher();
    } else if (event.altKey && !event.metaKey && (key === "arrowup" || key === "arrowdown")) {
      actions.move(key === "arrowdown" ? 1 : -1, event.shiftKey);
    } else if (key === "escape" && actions.escape()) {
      // handled
    } else if (plain && !typing(event.target) && "jkrtce".includes(key) && key.length === 1) {
      if (key === "j") actions.cursor(1);
      else if (key === "k") actions.cursor(-1);
      else if (key === "r") actions.reply();
      else if (key === "t") actions.toggleThread();
      else if (key === "c") actions.copyLink();
      else actions.resolve();
    } else {
      return;
    }
    event.preventDefault();
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => onKeyDown(event);
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, []);
}
