// The page's global keys, isolated in one narrow effect: Cmd-K opens the switcher, Option-Up and
// Option-Down move through the rail, Option-Shift-Up/Down jump to the next unread conversation,
// Escape closes the switcher, then the thread.
import { useEffect, useRef } from "react";

export interface HomeKeyActions {
  openSwitcher(): void;
  move(delta: 1 | -1, unreadOnly: boolean): void;
  escape(): boolean;
}

export function useHomeKeys(actions: HomeKeyActions): void {
  const latest = useRef(actions);
  latest.current = actions;
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing) return;
      const key = event.key.toLowerCase();
      if (key === "k" && event.metaKey && !event.shiftKey && !event.altKey) {
        latest.current.openSwitcher();
      } else if (event.altKey && !event.metaKey && (key === "arrowup" || key === "arrowdown")) {
        latest.current.move(key === "arrowdown" ? 1 : -1, event.shiftKey);
      } else if (key === "escape" && latest.current.escape()) {
        // handled
      } else {
        return;
      }
      event.preventDefault();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}
