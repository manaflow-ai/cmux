// FOCUS-RING: the one owner of whether a page draws focus rings (Leo, 2026-11-06: "i need the
// focus ring to STOP FIRING SO OFTEN AND TO BE ABLE TO CANCEL IT JUST GETS STUCK IN THESE
// SITUATIONS"). The browser's own `:focus-visible` is no rule for this: a text field matches it on a
// click, and WebKit turns it on for any programmatic focus that follows a key press, a Cmd shortcut
// included, then keeps it until focus leaves. So every page kept a ring nobody earned, and nothing
// but moving focus could clear it.
//
// The rule, kept here and nowhere else:
// - The ring is earned only when a navigation key (Tab, the arrows, Home, End, Page Up or Down,
//   with no Cmd, Ctrl or Option) moves focus. A click, a shortcut or code moving focus earns none.
// - A press anywhere, Escape or any other key that is not a navigation key (Enter, Space, a letter),
//   a scroll, the pointer moving more than a few pixels, or the page losing the window takes it away
//   at once, without moving focus. A modifier pressed alone (Shift before Shift-Tab) does not.
// - Every focus change within a navigation key's short window counts as that key's: one Tab can move
//   focus more than once (a focus guard handing it on to the first control, a handler focusing a
//   list and then its row), and each of those is the key's move.
// - The state lives on the root (`data-focus-modality`), so it can never outlive what set it: the
//   next pointer or key event, or the window's blur, always overwrites it.
//
// Every stylesheet's `:focus-visible` reads this state through FOCUS_RING_GATE, which the build adds
// after each `:focus-visible` (postcss.config.mjs, scripts/postcss/focusRingGate.mjs), so no rule
// can draw a ring the keyboard did not earn and no new rule has to remember to ask. Code that asks
// whether an element shows its ring calls focusRingShown, never `matches(":focus-visible")`
// (test/focus-modality.test.ts refuses that).
//
// Cost: three listeners per page, each a compare and at most one attribute write. The pointer-move
// listener is attached only while the ring is earned, so moving the mouse costs nothing otherwise.

/** The root attribute: `keyboard` while a navigation key earned the ring, `pointer` otherwise. */
export const FOCUS_MODALITY_ATTRIBUTE = "data-focus-modality";

/** What the build appends after every `:focus-visible` (scripts/postcss/focusRingGate.mjs keeps the
 * same text): the element is not under a root whose ring is off. A page that never installed this
 * module has no attribute, so its rings behave as before. */
export const FOCUS_RING_GATE = `:not(:root[${FOCUS_MODALITY_ATTRIBUTE}="pointer"] *)`;

export type FocusModality = "keyboard" | "pointer";

/** Keys that move focus. Space, Enter and letters act on what has focus; they earn no ring. */
const NAVIGATION_KEYS = new Set([
  "Tab",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
]);

/** Keys that only modify the next one; pressed alone they leave the ring as it is. */
const MODIFIER_KEYS = new Set(["Shift", "Meta", "Control", "Alt", "CapsLock", "Fn", "FnLock", "Hyper", "Super", "OS"]);

/** How long after a navigation key a focus change still counts as that key's: the browser's own
 * Tab move and a handler's `focus()` both land within the key's own task, well inside this. */
export const EARN_WINDOW_MS = 150;

/** How far the pointer may drift (a hand resting on the trackpad) before it takes the ring away. */
export const POINTER_SLOP_PX = 6;

const installed = new WeakSet<Document>();

/** Whether `doc`'s rings are on now. */
export function focusModality(doc: Document = document): FocusModality {
  return doc.documentElement.getAttribute(FOCUS_MODALITY_ATTRIBUTE) === "keyboard" ? "keyboard" : "pointer";
}

/** Whether `element` draws its focus ring now: it has keyboard focus (`:focus-visible`) and the
 * keyboard earned it. The JS side of FOCUS_RING_GATE; use it instead of `matches(":focus-visible")`. */
export function focusRingShown(element: Element | null | undefined): boolean {
  if (!element?.matches(":focus-visible")) return false;
  return element.ownerDocument.documentElement.getAttribute(FOCUS_MODALITY_ATTRIBUTE) !== "pointer";
}

/** Takes the ring away now (a dialog or menu closing by its own choice, for one). */
export function dismissFocusRing(doc: Document = document): void {
  doc.documentElement.setAttribute(FOCUS_MODALITY_ATTRIBUTE, "pointer");
}

function isNavigationKey(event: KeyboardEvent): boolean {
  return NAVIGATION_KEYS.has(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey;
}

/** Installs the owner once on `doc` (the desktop layer does it for every page). Returns a stop for
 * tests and galleries. */
export function installFocusModality(doc: Document = document): () => void {
  const view = doc.defaultView;
  if (!view || installed.has(doc)) return () => {};
  installed.add(doc);
  const root = doc.documentElement;
  const now = () => view.performance.now();
  let navigationKeyAt = Number.NEGATIVE_INFINITY;
  let anchor: { x: number; y: number } | null = null;

  const onPointerMove = (event: PointerEvent) => {
    if (!anchor) {
      anchor = { x: event.clientX, y: event.clientY };
      return;
    }
    if (Math.abs(event.clientX - anchor.x) + Math.abs(event.clientY - anchor.y) > POINTER_SLOP_PX) set("pointer");
  };
  const set = (next: FocusModality) => {
    if (root.getAttribute(FOCUS_MODALITY_ATTRIBUTE) === next) return;
    root.setAttribute(FOCUS_MODALITY_ATTRIBUTE, next);
    anchor = null;
    if (next === "keyboard") view.addEventListener("pointermove", onPointerMove, true);
    else view.removeEventListener("pointermove", onPointerMove, true);
  };

  const onKeyDown = (event: KeyboardEvent) => {
    if (isNavigationKey(event)) navigationKeyAt = now();
    else if (!MODIFIER_KEYS.has(event.key)) set("pointer");
  };
  // Every focus change decides afresh: a navigation key just before it earns the ring; anything
  // else (a click, a shortcut, code) clears it, even while the ring was on.
  const onFocusIn = () => set(now() - navigationKeyAt <= EARN_WINDOW_MS ? "keyboard" : "pointer");
  // A navigation key that keeps focus where it is (an arrow in a list that only moves its
  // highlight) leaves the ring as it was; a later key that does move focus earns it then.
  const clear = () => set("pointer");

  set("pointer");
  // Capture on the window: ahead of every page handler, so a handler that reads focusRingShown in
  // its own focus or key handling sees this event's answer.
  view.addEventListener("keydown", onKeyDown, true);
  doc.addEventListener("focusin", onFocusIn, true);
  view.addEventListener("pointerdown", clear, true);
  view.addEventListener("wheel", clear, { capture: true, passive: true });
  view.addEventListener("blur", clear);
  return () => {
    view.removeEventListener("keydown", onKeyDown, true);
    doc.removeEventListener("focusin", onFocusIn, true);
    view.removeEventListener("pointerdown", clear, true);
    view.removeEventListener("wheel", clear, true);
    view.removeEventListener("blur", clear);
    view.removeEventListener("pointermove", onPointerMove, true);
    root.removeAttribute(FOCUS_MODALITY_ATTRIBUTE);
    installed.delete(doc);
  };
}
