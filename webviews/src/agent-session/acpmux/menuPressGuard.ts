import { useEffect } from "react";

// A press outside an open composer menu only closes it (cg-composer click polish): a macOS menu
// and Codex's menus swallow the click that dismisses them, so the mic does not start dictation and
// the field takes no click or caret. A press on another menu button still opens that menu at once
// (one press switches menus), and a press inside the open menu is the menu's own.
//
// The menus close themselves on that press: Base UI's dismiss, the model picker's and the + menu's
// listeners watch the document in the capture phase, and Base UI closes from a listener it adds on
// the pressed element. So the guard lets each event reach that element, then stops it there, before the
// page's own handlers (React's, on the root) see it; and it cancels the press's default, so no
// focus or caret moves, and the click's.

/** A composer chip whose menu is open: the chat composer's bar and strip, and the New Tab card's. */
const OPEN_CHIP =
  ':is(.acpmux-composer, .nt-composer) :is([aria-haspopup][aria-expanded="true"], [aria-haspopup][data-popup-open])';
/** What a press may still reach: the open menu itself, and any menu button (it switches menus). */
const PASSES = ".ui-positioner, .ui-popup, [aria-haspopup]";
const SWALLOWED = ["pointerdown", "mousedown", "pointerup", "mouseup", "click"] as const;

let installed: { doc: Document; count: number; remove(): void } | null = null;

/** Installs the guard on the page for as long as a composer is mounted. */
export function useMenuPressGuard() {
  useEffect(() => installMenuPressGuard(document), []);
}

/** Installs the guard on `doc` (once, however many composers ask); returns its removal. */
export function installMenuPressGuard(doc: Document): () => void {
  if (installed?.doc === doc) {
    installed.count += 1;
  } else {
    installed?.remove();
    installed = { doc, count: 1, remove: install(doc) };
  }
  let released = false;
  return () => {
    if (released || installed?.doc !== doc) return;
    released = true;
    installed.count -= 1;
    if (installed.count > 0) return;
    installed.remove();
    installed = null;
  };
}

function install(doc: Document): () => void {
  const view = doc.defaultView;
  if (!view) return () => {};
  let swallowing: number | null = null;
  // Decided first, on the window, while the menu is still open: the menus close on this press.
  const decide = (event: PointerEvent) => {
    if (!event.isPrimary) return;
    const target = event.target instanceof Element ? event.target : null;
    swallowing =
      event.button === 0 && !!doc.querySelector(OPEN_CHIP) && !target?.closest(PASSES) ? event.pointerId : null;
  };
  const cancel = (event: PointerEvent) => {
    if (event.pointerId === swallowing) swallowing = null;
  };
  const blur = () => {
    swallowing = null;
  };
  const stop = (event: Event) => {
    event.stopPropagation();
    if (event.type === "mousedown" || event.type === "click") event.preventDefault();
  };
  const swallow = (event: Event) => {
    if (swallowing === null) return;
    // Keyboard and programmatic activations do not belong to the pointer gesture. In particular,
    // releasing a drag outside the window may never deliver its click to clear the guard.
    if (event.type === "click" && (event as MouseEvent).detail === 0) return;
    // Only the pointer events carry the gesture's id; a click may be a PointerEvent with another id.
    if (event.type.startsWith("pointer") && (event as PointerEvent).pointerId !== swallowing) return;
    if (event.type === "click") swallowing = null;
    // After the dismiss's own listener on the target (added in the document's capture phase).
    event.target?.addEventListener(event.type, stop, { once: true });
  };
  view.addEventListener("pointerdown", decide, true);
  view.addEventListener("pointercancel", cancel, true);
  view.addEventListener("blur", blur);
  for (const type of SWALLOWED) doc.body.addEventListener(type, swallow, true);
  return () => {
    view.removeEventListener("pointerdown", decide, true);
    view.removeEventListener("pointercancel", cancel, true);
    view.removeEventListener("blur", blur);
    for (const type of SWALLOWED) doc.body.removeEventListener(type, swallow, true);
  };
}
