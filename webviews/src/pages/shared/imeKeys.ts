// IME-KEYS (cx-dd5b4): a key that belongs to an input method never reaches a page's key handlers.
//
// While an input method composes (Japanese, Chinese, Korean, Vietnamese, a dead key), the browser
// still dispatches keydown and keyup for the keys the IME uses: Return or Space commits a
// candidate, Escape cancels the composition, the arrows move in the candidate list, Backspace
// edits the preedit. A handler that acts on those keys (Return submits, Escape clears the field,
// ArrowDown moves the list selection) takes the user's composition keys. cmux-classic had this bug
// in every field that had its own key handler; each fix was one more hand-placed check.
//
// The rule is one layer, installed with the desktop layer before any page code: during
// composition, keydown and keyup stop at the window (capture phase), so no page, React or library
// handler sees them. The default action is not prevented: the input method still gets the key.
//
// The signal is the one the engines give: `isComposing` during composition, and keyCode 229 for
// the key the IME processed. WebKit sends the key that ends a composition (Return that commits)
// after `compositionend`, with `isComposing` false and keyCode 229, so both checks are needed.

/** Whether `event` is a key an input method processed (composition keys, the committing key). */
export function isImeKeyEvent(event: Pick<KeyboardEvent, "isComposing" | "keyCode">): boolean {
  return event.isComposing || event.keyCode === 229;
}

const INSTALLED = "data-cmux-ime-keys";

/**
 * Editors that run their own composition handling and read the IME keys for it: ProseMirror
 * clears its Safari after-composition guard on the 229 keydown, Monaco tracks it for the
 * press-and-hold accent menu (and stops it itself). Their keys reach them; their own submit
 * checks must test `isImeKeyEvent`.
 */
const OWN_COMPOSITION = ".ProseMirror, .monaco-editor";

/** Installs the IME key layer on `doc`'s window once. */
export function installImeKeyLayer(doc: Document = document): void {
  const root = doc.documentElement;
  const view = doc.defaultView;
  if (!view || root.hasAttribute(INSTALLED)) return;
  root.setAttribute(INSTALLED, "");
  const stop = (event: KeyboardEvent) => {
    if (!isImeKeyEvent(event)) return;
    if (event.target instanceof Element && event.target.closest(OWN_COMPOSITION)) return;
    event.stopImmediatePropagation();
  };
  // ui-allow: the IME key layer for every page, not a widget key handler
  view.addEventListener("keydown", stop, { capture: true });
  // ui-allow: the IME key layer for every page, not a widget key handler
  view.addEventListener("keyup", stop, { capture: true });
}
