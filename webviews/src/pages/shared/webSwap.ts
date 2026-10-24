// WEB-SWAP (plans/cmux-next/web-ota.md, "The safe point"): a page's answer when a web update is
// ready to reload it in place. The host (WebUpdates+SafePoint.swift) asks every served page
// `window.cmuxWebSwap.hold()` once nobody has touched cmux for a while; the update swaps in only
// when every page answers null. A page answers why not while a reload would lose or disturb what
// it holds: a hold a component registered (a prompt being sent, chips the host does not keep yet),
// an input method composing, a selection, a focused field that does not come back, a caret that
// would move, an open menu or dialog, or a scroller away from where the page opens.
//
// Installed with the desktop layer, so every first-party page answers. A page without it (or one
// that does not answer) keeps the update waiting.

/** Why a reload now would lose or disturb something, or null/undefined when it would not. */
export type WebSwapHold = () => string | null | undefined;

/** On a scroller whose place the page keeps and restores itself (the chat transcript). */
export const WEB_SWAP_KEPT_SCROLL = "data-cmux-swap-scroll";
/** On the part of a page that restores its own focus after a swap (the composer, `takeWebSwapFocus`). */
export const WEB_SWAP_FOCUS = "data-cmux-swap-focus";
/** sessionStorage (it survives a reload): the focus owner to give the keyboard back to, and when. */
export const WEB_SWAP_FOCUS_KEY = "cmux.webSwap.focus";
/** A stash older than this is from a look that did not swap: it is ignored. */
export const WEB_SWAP_FOCUS_FRESH_MS = 10_000;
/** What counts as an open menu, popover or dialog (as ChatInspector and WidgetEditing read it). */
const OPEN_POPUP =
  'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], .ui-popup, [aria-haspopup]:not([aria-haspopup="false"])[aria-expanded="true"], [role="combobox"][aria-expanded="true"]';

const holds = new Set<WebSwapHold>();
const composing = new WeakSet<Document>();

/** Holds swaps while `hold` answers a reason; returns the release (call it on unmount). */
export function holdWebSwap(hold: WebSwapHold): () => void {
  holds.add(hold);
  return () => void holds.delete(hold);
}

/** The page's answer: null when a reload now keeps everything it holds, else why not. */
export function webSwapHold(doc: Document = document): string | null {
  for (const hold of holds) {
    const reason = hold();
    if (reason) return reason;
  }
  if (composing.has(doc)) return "ime";
  const view = doc.defaultView;
  const selection = view?.getSelection();
  const active = doc.activeElement;
  if (isTextField(active)) {
    if (active.selectionStart !== active.selectionEnd) return "selection";
  } else if (selection && !selection.isCollapsed) {
    return "selection";
  }
  if (active && isEditable(active)) {
    if (!active.closest(`[${WEB_SWAP_FOCUS}]`)) return "focus";
    if (!caretAtEnd(active, selection)) return "caret";
  }
  if (doc.querySelector(OPEN_POPUP)) return "popup";
  for (const element of doc.querySelectorAll<HTMLElement>("*")) {
    if (element.hasAttribute(WEB_SWAP_KEPT_SCROLL)) continue;
    if (Math.abs(element.scrollTop) > 1 || Math.abs(element.scrollLeft) > 1) return "scroll";
  }
  return null;
}

/** After a swap: whether the focus owner `key` had the keyboard, read once (the composer focuses itself). */
export function takeWebSwapFocus(key: string, now = Date.now()): boolean {
  let stash: string | null = null;
  try {
    stash = sessionStorage.getItem(WEB_SWAP_FOCUS_KEY);
    if (!stash) return false;
    const { owner, at } = JSON.parse(stash) as { owner?: unknown; at?: unknown };
    if (owner !== key) return false;
    sessionStorage.removeItem(WEB_SWAP_FOCUS_KEY);
    return typeof at === "number" && now - at < WEB_SWAP_FOCUS_FRESH_MS;
  } catch {
    return false;
  }
}

/** Answers the host's ask (`window.cmuxWebSwap`) and tracks input method composition. Once per document. */
export function installWebSwap(doc: Document = document): void {
  const view = doc.defaultView as (Window & { cmuxWebSwap?: { hold(): string | null } }) | null;
  if (!view || view.cmuxWebSwap) return;
  view.addEventListener("compositionstart", () => composing.add(doc), { capture: true });
  view.addEventListener("compositionend", () => composing.delete(doc), { capture: true });
  view.cmuxWebSwap = {
    hold() {
      const reason = webSwapHold(doc);
      if (reason) return reason;
      // The reload comes next: the focus owner gets the keyboard back once the page is up again.
      const owner = doc.activeElement?.closest(`[${WEB_SWAP_FOCUS}]`)?.getAttribute(WEB_SWAP_FOCUS);
      try {
        if (owner) view.sessionStorage.setItem(WEB_SWAP_FOCUS_KEY, JSON.stringify({ owner, at: Date.now() }));
        else view.sessionStorage.removeItem(WEB_SWAP_FOCUS_KEY);
      } catch {
        // No storage: the page comes back without the keyboard, which loses nothing.
      }
      return null;
    },
  };
}

type TextField = HTMLInputElement | HTMLTextAreaElement;

function isTextField(element: Element | null): element is TextField {
  if (!element) return false;
  if (element.tagName === "TEXTAREA") return true;
  if (element.tagName !== "INPUT") return false;
  // Only the input types with a caret; a checkbox or button keeps nothing a reload loses.
  return /^(text|search|url|tel|email|password|number|)$/.test((element as HTMLInputElement).type ?? "");
}

function isEditable(element: Element): boolean {
  if (isTextField(element) || (element as HTMLElement).isContentEditable === true) return true;
  const editable = element.getAttribute("contenteditable");
  return editable === "" || editable === "true" || editable === "plaintext-only";
}

/** Whether the caret sits after all of the field's text (where a restored draft puts it). */
function caretAtEnd(element: Element, selection: Selection | null | undefined): boolean {
  if (isTextField(element)) return element.selectionEnd === element.value.length;
  if (!selection?.focusNode || !element.contains(selection.focusNode)) return true;
  const after = element.ownerDocument.createRange();
  after.setStart(selection.focusNode, selection.focusOffset);
  after.setEnd(element, element.childNodes.length);
  return after.toString().trim() === "";
}
