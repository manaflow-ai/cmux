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
 * module has no attribute, so its rings behave as before. Inside `:where()` it adds no specificity,
 * so a gated rule weighs what it did before (the shell composer's own rim still outranks the focus
 * rim). */
export const FOCUS_RING_GATE = `:where(:not(:root[${FOCUS_MODALITY_ATTRIBUTE}="pointer"] *))`;

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

/** Each installed document's own state changes, so `earnFocusRing` and `dismissFocusRing` go
 * through them. */
const installed = new WeakMap<
  Document,
  { set: (next: FocusModality) => void; clear: () => void; keyed: () => Element | null }
>();

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

/** Whether `element` holds focus a navigation key gave it, whether or not its ring still shows: a
 * pointer move takes the ring away but the keyboard still works there. For behavior that follows
 * where focus came from (a rail that keeps keyboard focus, drops a click's); a ring's look asks
 * focusRingShown. */
export function focusCameFromKey(element: Element | null | undefined): boolean {
  if (!element) return false;
  const doc = element.ownerDocument;
  return doc.activeElement === element && installed.get(doc)?.keyed() === element;
}

/** Takes the ring away now and forgets the last navigation key, so the focus that follows earns
 * none: a dialog or menu closing by its own choice, or the app running a command its own key router
 * took (Cmd-F's `focusSearch`), whose key the page never sees. */
export function dismissFocusRing(doc: Document = document): void {
  const owner = installed.get(doc);
  if (owner) owner.clear();
  else doc.documentElement.setAttribute(FOCUS_MODALITY_ATTRIBUTE, "pointer");
}

/** Turns the ring on for what has focus now, as a navigation key would. Only for stagings that
 * stand in for a key (a gallery's focus step); product code lets the keyboard earn it. */
export function earnFocusRing(doc: Document = document): void {
  installed.get(doc)?.set("keyboard");
}

function isNavigationKey(event: KeyboardEvent): boolean {
  return NAVIGATION_KEYS.has(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey;
}

/** Installs the owner once on `doc` (the desktop layer does it for every page). Returns a stop for
 * tests and galleries. */
export function installFocusModality(doc: Document = document): () => void {
  const view = doc.defaultView;
  if (!view || installed.has(doc)) return () => {};
  const root = doc.documentElement;
  const now = () => view.performance.now();
  let navigationKeyAt = Number.NEGATIVE_INFINITY;
  let anchor: { x: number; y: number } | null = null;
  // The element the last focus change gave to a navigation key (focusCameFromKey).
  let keyed: Element | null = null;

  const onPointerMove = (event: PointerEvent) => {
    // The first move after the ring is earned measures from where it started (its own movement),
    // so one long move takes the ring away too.
    anchor ??= { x: event.clientX - (event.movementX || 0), y: event.clientY - (event.movementY || 0) };
    if (Math.abs(event.clientX - anchor.x) + Math.abs(event.clientY - anchor.y) > POINTER_SLOP_PX) clear();
  };
  const set = (next: FocusModality) => {
    if (root.getAttribute(FOCUS_MODALITY_ATTRIBUTE) === next) return;
    root.setAttribute(FOCUS_MODALITY_ATTRIBUTE, next);
    anchor = null;
    if (next === "keyboard") view.addEventListener("pointermove", onPointerMove, true);
    else view.removeEventListener("pointermove", onPointerMove, true);
  };

  // Taking the ring away also forgets the last navigation key, so a focus move that follows (a
  // click's, or an Escape handler's within the key's window) cannot earn it back.
  const clear = () => {
    navigationKeyAt = Number.NEGATIVE_INFINITY;
    set("pointer");
  };
  // A navigation key's focus moves happen in its own task and the frame after (a focus guard, a
  // handler, an effect, a list focusing its row once drawn). After the second frame the key is
  // spent, so a later focus from code, or from a key the app's router took, cannot borrow it.
  let keyToken = 0;
  const onKeyDown = (event: KeyboardEvent) => {
    if (isNavigationKey(event)) {
      navigationKeyAt = now();
      const token = (keyToken += 1);
      view.requestAnimationFrame?.(() =>
        view.requestAnimationFrame(() => {
          if (token === keyToken) navigationKeyAt = Number.NEGATIVE_INFINITY;
        }),
      );
    } else if (!MODIFIER_KEYS.has(event.key)) clear();
  };
  // Every focus change decides afresh: a navigation key just before it earns the ring; anything
  // else (a click, a shortcut, code) clears it, even while the ring was on.
  const onFocusIn = (event: FocusEvent) => {
    const earned = now() - navigationKeyAt <= EARN_WINDOW_MS;
    keyed = earned ? (event.target as Element) : null;
    set(earned ? "keyboard" : "pointer");
    // A ring that moved by key measures pointer travel afresh from its new place.
    if (earned) anchor = null;
  };
  // A navigation key that keeps focus where it is (an arrow in a list that only moves its
  // highlight) leaves the ring as it was; a later key that does move focus earns it then.

  installed.set(doc, { set, clear, keyed: () => keyed });
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
