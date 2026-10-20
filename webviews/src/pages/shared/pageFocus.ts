// The DOM half of pane focus (plans/cmux-next/pane-focus-DESIGN.md): the app makes the page's web
// view first responder and sends `focusContent`; WebKit then restores the element that had focus in
// this document, or none. With none, keys reach the body and typing goes nowhere. `contentFocus`
// focuses the page's primary input at that moment, only when nothing else in the page has focus, so
// a clicked field, an open find widget or a restored element keeps the keyboard. A request that
// comes before the input exists (a lazy editor) is kept and applied once when it mounts.

/** Something that takes the keyboard: the page's primary input (`MonacoView`, a text field). */
export interface Focusable {
  focus(): void;
}

/** The page command the host sends each time the page's web view gets the keyboard. */
export const FOCUS_CONTENT_COMMAND = "focusContent";

export interface ContentFocus {
  /** The host gave the page the keyboard (`focusContent`, the window's `focus` event). */
  request(): void;
  /** The primary input exists now (or went away: null); a kept request applies to it. */
  mount(target: Focusable | null): void;
  /** Stops listening to the window. */
  dispose(): void;
}

/** Whether no element in `doc` has the keyboard (only the body or the root does). */
export function nothingFocused(doc: Document): boolean {
  const active = doc.activeElement;
  return active == null || active === doc.body || active === doc.documentElement;
}

/**
 * Focuses `target` whenever the page gets the keyboard and nothing in it has focus. Listens to
 * `win`'s `focus` event (WebKit's signal for the web view becoming first responder in a key
 * window); call `request()` for the host's `focusContent` command.
 */
export function contentFocus(win: Window = window, doc: Document = document): ContentFocus {
  let target: Focusable | null = null;
  let pending = false;
  const request = () => {
    if (!nothingFocused(doc)) {
      pending = false;
      return;
    }
    if (target) {
      pending = false;
      target.focus();
    } else {
      pending = true;
    }
  };
  const onFocus = () => request();
  win.addEventListener("focus", onFocus);
  return {
    request,
    mount(next) {
      target = next;
      if (next && pending) request();
    },
    dispose() {
      win.removeEventListener("focus", onFocus);
    },
  };
}
