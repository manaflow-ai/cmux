// The page's global keys, isolated in one narrow effect: Cmd-K opens the switcher, Option-Up and
// Option-Down move through the rail, Option-Shift-Up/Down jump to the next unread conversation,
// Escape closes the switcher, then the editor, then the thread. The listener is attached once; it
// calls the latest actions through an Effect Event, so no ref is written during render.
import { useEffect, useEffectEvent } from "react";

export interface HomeKeyActions {
  openSwitcher(): void;
  move(delta: 1 | -1, unreadOnly: boolean): void;
  escape(): boolean;
}

export function useHomeKeys(actions: HomeKeyActions): void {
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    if (event.defaultPrevented || event.isComposing) return;
    // A popup (menu, popover, picker) owns its own Escape and arrows.
    if (event.target instanceof Element && event.target.closest(".ui-popup")) return;
    const key = event.key.toLowerCase();
    if (key === "k" && event.metaKey && !event.shiftKey && !event.altKey) {
      actions.openSwitcher();
    } else if (event.altKey && !event.metaKey && (key === "arrowup" || key === "arrowdown")) {
      actions.move(key === "arrowdown" ? 1 : -1, event.shiftKey);
    } else if (key === "escape" && actions.escape()) {
      // handled
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
