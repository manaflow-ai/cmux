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
//
// A queued prompt's controls act on that one press as well (Leo on nightly 331e2e9, 2026-10-21: "WHY
// CAN'T I CLICK THESE BUTTONS"): Steer, the trash can, ⋯, the prompt's text and the queue's fold and
// Resume. Each is a deliberate action on a prompt waiting above the bar, not a stray press near the
// menu, and swallowing it left the first press only closing the chip. The menu still closes on that
// press; the mic and the field still take nothing.

/** A composer chip whose menu is open: the chat composer's bar and strip, and the New Tab card's. */
const OPEN_CHIP =
  ':is(.acpmux-composer, .nt-composer) :is([aria-haspopup][aria-expanded="true"], [aria-haspopup][data-popup-open])';
/** What a press may still reach: the open menu itself, any menu button (it switches menus), and a
 *  queued prompt's controls (ComposerQueue.tsx). */
const PASSES =
  ".ui-positioner, .ui-popup, [aria-haspopup], .acpmux-composer-queue button, .acpmux-queue-foldbar button";
const SWALLOWED = ["pointerdown", "mousedown", "pointerup", "mouseup", "click"] as const;

/**
 * A chip says its menu is open and the menu is on screen: the popup it names (`aria-controls`), or,
 * when it names none, a positioned popup (`Popover` and `Menu` portal theirs into a positioner; the
 * slash and mention menus inline in the field are not a chip's). A chip left saying open with no
 * menu showing must not swallow every press in the composer (Leo, 2026-10-21: "WHY THE FUCK CANT I
 * CLICK THESE BUTTONS").
 */
function menuOnScreen(doc: Document): boolean {
  for (const chip of doc.querySelectorAll(OPEN_CHIP)) {
    const controls = chip.getAttribute("aria-controls");
    if (controls ? doc.getElementById(controls) : doc.querySelector(".ui-positioner .ui-popup")) return true;
  }
  return false;
}

let installed: { doc: Document; count: number; remove(): void; swallowing(): boolean } | null = null;

/** Whether the press now under way only closes a composer menu (another handler should ignore it). */
export function swallowsPress(doc: Document): boolean {
  return installed?.doc === doc && installed.swallowing();
}

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
    installed = { doc, count: 1, ...install(doc) };
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

function install(doc: Document): { remove(): void; swallowing(): boolean } {
  const view = doc.defaultView;
  if (!view) return { remove: () => {}, swallowing: () => false };
  let swallowing: number | null = null;
  // Decided first, on the window, while the menu is still open: the menus close on this press.
  const decide = (event: PointerEvent) => {
    if (!event.isPrimary) return;
    const target = event.target instanceof Element ? event.target : null;
    swallowing = event.button === 0 && menuOnScreen(doc) && !target?.closest(PASSES) ? event.pointerId : null;
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
  return {
    remove: () => {
      view.removeEventListener("pointerdown", decide, true);
      view.removeEventListener("pointercancel", cancel, true);
      view.removeEventListener("blur", blur);
      for (const type of SWALLOWED) doc.body.removeEventListener(type, swallow, true);
    },
    swallowing: () => swallowing !== null,
  };
}
