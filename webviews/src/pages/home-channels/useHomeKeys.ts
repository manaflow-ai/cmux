// The page's global keys, isolated in one narrow effect: Cmd-K opens the palette, Option-Up and
// Option-Down move through the conversation list (Option-Shift: the next unread one), Escape closes
// the palette, then the editor, then the thread. Outside a text field the work keys act on the
// keyboard's row: j/k move, Return opens, r reply, t thread, c copy link, e resolve or reopen. The
// listener is attached once; it calls the latest actions through an Effect Event, so no ref is
// written during render.
import { useEffect, useEffectEvent } from "react";

export type WorkKey = "j" | "k" | "enter" | "r" | "t" | "c" | "e";

export interface HomeKeyActions {
  openSwitcher(): void;
  move(delta: 1 | -1, unreadOnly: boolean): void;
  escape(): boolean;
  /** A work key outside a text field; true when it acted. */
  work(key: WorkKey): boolean;
}

const WORK_KEYS: Record<string, WorkKey> = { j: "j", k: "k", enter: "enter", r: "r", t: "t", c: "c", e: "e" };

function inTextField(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  return target.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']") !== null;
}

export function useHomeKeys(actions: HomeKeyActions): void {
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    if (event.defaultPrevented || event.isComposing) return;
    // A popup (menu, popover, picker) owns its own Escape and arrows.
    if (event.target instanceof Element && event.target.closest(".ui-popup, [role='dialog']")) {
      if (!(event.key.toLowerCase() === "k" && event.metaKey)) return;
    }
    const key = event.key.toLowerCase();
    const plain = !event.metaKey && !event.ctrlKey && !event.altKey;
    if (key === "k" && event.metaKey && !event.shiftKey && !event.altKey) {
      actions.openSwitcher();
    } else if (event.altKey && !event.metaKey && (key === "arrowup" || key === "arrowdown")) {
      actions.move(key === "arrowdown" ? 1 : -1, event.shiftKey);
    } else if (key === "escape" && actions.escape()) {
      // handled
    } else if (plain && !event.shiftKey && WORK_KEYS[key] && !inTextField(event.target)) {
      // A focused button already answers Return itself.
      if (key === "enter" && event.target instanceof HTMLButtonElement) return;
      if (!actions.work(WORK_KEYS[key]!)) return;
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
