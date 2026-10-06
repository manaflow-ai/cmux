import { useEffect, useRef } from "react";

// The composer takes the keyboard inside the agent pane: it is focused when the pane opens
// or becomes active with nothing else focused in it, and a printed key typed while focus sits
// elsewhere in the pane (a session row, the transcript) goes into it. Only this page's own
// focus moves: the page cannot take focus from another pane or app, and a key reaches the
// page only when its pane already has the keyboard.

/// Sent on window by MarkdownField when its editor exists, so a composer that appears after
/// the page opened (a new chat, the handshake) still takes an idle focus.
export const COMPOSER_READY_EVENT = "acpmux-composer-ready";

export type KeyLike = {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  isComposing: boolean;
  defaultPrevented: boolean;
};

/// Controls that own their keys: text fields, and widgets that move or pick with keys.
const OWNS_KEYS =
  'input, textarea, select, [contenteditable=""], [contenteditable="true"], [role="textbox"], [role="menu"], [role="menubar"], [role="listbox"], [role="dialog"], [role="tree"], [role="grid"], [role="combobox"]';
const PRESSABLE =
  'button, a[href], [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], summary';

/// Whether a key typed with `target` focused should go into the composer.
export function routesToComposer(event: KeyLike, target: Element | null): boolean {
  if (event.defaultPrevented || event.isComposing) return false;
  if (event.metaKey || event.ctrlKey || event.altKey) return false;
  // One printed character: named keys (Enter, arrows, Escape, Tab) keep their meaning.
  if (event.key.length > 1 && /^[A-Za-z0-9]+$/.test(event.key)) return false;
  if (!target || target === target.ownerDocument?.body) return true;
  if (target.closest(OWNS_KEYS)) return false;
  if (event.key === " " && target.closest(PRESSABLE)) return false;
  return true;
}

/// What has the page's focus, for automation (chat_state): `composer`, `none`, or
/// `tag#id.class` of the focused element.
export function focusedArea(element: Element | null): string {
  if (!element || element === element.ownerDocument?.body) return "none";
  if (element.closest(".acpmux-composer-box")) return "composer";
  const id = element.id ? `#${element.id}` : "";
  const className =
    typeof element.className === "string" && element.className ? `.${element.className.split(/\s+/)[0]}` : "";
  return `${element.tagName.toLowerCase()}${id}${className}`;
}

/// Installs the composer's claim on the keyboard. `focusComposer` focuses the prompt and
/// returns false when no composer is shown.
export function useComposerKeyboard(focusComposer: () => boolean) {
  const latest = useRef(focusComposer);
  latest.current = focusComposer;
  useEffect(() => {
    const claimIfIdle = () => {
      const active = document.activeElement;
      if (!active || active === document.body) latest.current();
    };
    const onKey = (event: KeyboardEvent) => {
      if (!routesToComposer(event, document.activeElement)) return;
      if (!latest.current()) return;
      event.preventDefault();
      // The field has the caret now; insertText goes through its input handling like typing.
      document.execCommand("insertText", false, event.key);
    };
    // The page opened (first paint) or its pane became active (the window and web view took focus).
    const first = requestAnimationFrame(claimIfIdle);
    window.addEventListener("focus", claimIfIdle);
    window.addEventListener(COMPOSER_READY_EVENT, claimIfIdle);
    document.addEventListener("keydown", onKey);
    return () => {
      cancelAnimationFrame(first);
      window.removeEventListener("focus", claimIfIdle);
      window.removeEventListener(COMPOSER_READY_EVENT, claimIfIdle);
      document.removeEventListener("keydown", onKey);
    };
  }, []);
}
