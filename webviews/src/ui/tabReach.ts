// Where Tab goes when it leaves a layer drawn over other content (the toast deck, NoticeDeck.tsx;
// Jump to latest), and when it would enter a scroller at a stop out of view (the transcript).
// The browser's next tab stop is the next one in the document, seen or not: under the agent pane's
// toasts that was an element with no box (no focus ring anywhere) and then a transcript row the
// virtual list had rendered past the viewport's edge, which the browser scrolled to and so took the
// reader away from where they were reading (#38090). Leaving the layer, focus goes instead to the
// nearest tab stop in that direction that a person can see on screen.
//
// Read on a Tab key press only: one box and one hit test per stop passed over, never per frame.
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import { focusWithRing } from "./focusWithRing";

/// What the browser tabs to on its own: links, form controls, frames, players with controls, a
/// details' own summary (its first) and editable boxes. Anything else is a stop by a tabindex of 0 or
/// more, and these leave by one below 0.
const NATIVE_STOPS =
  'a[href], area[href], button, input, select, textarea, iframe, audio[controls], video[controls], details > summary:first-of-type, [contenteditable]:not([contenteditable="false"])';
const TAB_STOPS = `${NATIVE_STOPS}, [tabindex]`;

/// The element's own tabindex, when it sets a valid one.
function tabindexOf(element: HTMLElement): number | undefined {
  const value = element.getAttribute("tabindex")?.trim();
  return value && /^[+-]?\d+$/.test(value) ? Number.parseInt(value, 10) : undefined;
}

function isTabStop(element: HTMLElement): boolean {
  const order = tabindexOf(element);
  if (order !== undefined ? order < 0 : !element.matches(NATIVE_STOPS)) return false;
  if (element.closest("[inert]")) return false;
  // `:disabled`, not `.disabled`: a control inside a disabled fieldset (outside its first legend)
  // is disabled too, and the browser neither tabs to it nor lets it take focus.
  if (element.matches(":disabled")) return false;
  return !(element.tagName === "INPUT" && (element as HTMLInputElement).type === "hidden");
}

/// Focus is on (or in) something that moves Tab through controls of its own while the document's
/// focus stays on it: a player's play, timeline and volume, or a frame's page. The guards below
/// cannot tell its last inner control from its first, so they leave its Tab presses to the browser.
/// An editable box is not one: Tab leaves it (the composer's edge is a plain stop).
function ownsTab(element: Element | null): boolean {
  return element?.closest("audio, video, iframe") != null;
}

/// The tab stops under `root`, in document order.
export function tabStops(root: ParentNode): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>(TAB_STOPS)].filter(isTabStop);
}

/// Seen on screen: it has a box, its centre is inside the viewport, and what is drawn there is it
/// (not a scroller's clipped-off content, and not something covered by the layer over it).
export function onScreen(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return false;
  const view = element.ownerDocument.defaultView;
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  if (!view || x < 0 || y < 0 || x >= view.innerWidth || y >= view.innerHeight) return false;
  if (view.getComputedStyle(element).visibility === "hidden") return false;
  const hit = element.ownerDocument.elementFromPoint(x, y);
  return hit !== null && (hit === element || element.contains(hit));
}

/// The nearest tab stop outside `layer` in the direction of travel that is on screen, if any.
export function nearestStopOnScreen(layer: HTMLElement, backward: boolean): HTMLElement | undefined {
  const side = backward ? layer.DOCUMENT_POSITION_PRECEDING : layer.DOCUMENT_POSITION_FOLLOWING;
  const stops = tabStops(layer.ownerDocument).filter(
    (stop) => !layer.contains(stop) && (layer.compareDocumentPosition(stop) & side) !== 0,
  );
  if (backward) stops.reverse();
  return stops.find(onScreen);
}

/// The layer's own tab stops: its descendants', and the layer itself when it is one (a lone button
/// over the page, as Jump to latest is).
function layerStops(layer: HTMLElement): HTMLElement[] {
  const own = layer.matches(TAB_STOPS) && isTabStop(layer) ? [layer] : [];
  return [...own, ...tabStops(layer)];
}

/// A ref for a control drawn over the transcript on its own (Jump to latest, the Needs you pill):
/// Tab or Shift-Tab leaving it goes to a stop on screen, as it does out of the toast deck. Shift-Tab
/// out of the deck lands on Jump to latest, and the browser's next stop before it was a transcript
/// row rendered past the viewport's edge, which scrolled the reader away (#38090).
export function leaveOnScreenRef(element: HTMLElement | null): (() => void) | undefined {
  if (!element) return undefined;
  const key = (event: KeyboardEvent) => leaveLayerOnScreen(element, event);
  element.addEventListener("keydown", key);
  return () => element.removeEventListener("keydown", key);
}

/// A Tab key press inside `layer`: when it would leave the layer, focus goes to the nearest tab
/// stop on screen in that direction (with its focus ring) and the press is taken. Within the layer,
/// or with nothing on screen that way, the browser moves focus as usual.
export function leaveLayerOnScreen(layer: HTMLElement, event: KeyboardEvent | ReactKeyboardEvent): void {
  if (event.key !== "Tab" || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
  if (ownsTab(layer.ownerDocument.activeElement)) return;
  const inside = layerStops(layer);
  const edge = event.shiftKey ? inside[0] : inside.at(-1);
  if (!edge || event.target !== edge) return;
  const target = nearestStopOnScreen(layer, event.shiftKey);
  if (!target) return;
  event.preventDefault();
  focusWithRing(target, { preventScroll: true, focusVisible: true });
}

/// Whether `element` lies wholly above or below what `region` (a scroller) shows in the window:
/// scrolled out of view, so focusing it would scroll. A control in view with no box of its own
/// (inside text collapsed until focus opens it) is not.
function scrolledOut(element: HTMLElement, region: HTMLElement): boolean {
  const box = element.getBoundingClientRect();
  const view = region.getBoundingClientRect();
  const top = Math.max(view.top, 0);
  const bottom = Math.min(view.bottom, element.ownerDocument.defaultView?.innerHeight ?? view.bottom);
  return box.bottom <= top || box.top >= bottom;
}

/// Tab or Shift-Tab, from anywhere in the document, whose next stop would be a control in `region`
/// scrolled out of its view goes on to the nearest stop in view in that direction instead. The
/// transcript's virtual list mounts rows a little past each edge of the view, and each row's
/// controls are tab stops: from the composer (Shift-Tab), from the control above the rows (Tab),
/// or from the last row in view, the browser's next stop was such a row, and focusing it scrolled
/// the reader away from where they were reading (#38090). A stop in `region` counts while it is
/// inside the view and nothing outside the region is drawn over it, clipped or not, so Tab still
/// opens a sent message's collapsed text by reaching its controls. A stop outside it counts when
/// it is on screen. With nothing that way, the browser
/// moves focus as usual. A layer that already took the press (the toast deck, Jump to latest) is
/// left alone. Returns the cleanup.
export function keepTabOnScreen(region: HTMLElement): () => void {
  const doc = region.ownerDocument;
  // In the region: inside its view and not under something drawn over the region (the composer's
  // dock, a toast, Jump to latest). Clipping inside the region does not count against it: a sent
  // message's code controls sit in text collapsed until focus opens it, and Tab must reach them.
  const inView = (stop: HTMLElement) => {
    if (!region.contains(stop)) return onScreen(stop);
    if (scrolledOut(stop, region)) return false;
    const box = stop.getBoundingClientRect();
    if (box.width <= 0 || box.height <= 0) return true;
    const view = doc.defaultView;
    const x = box.left + box.width / 2;
    const y = box.top + box.height / 2;
    if (!view || x < 0 || y < 0 || x >= view.innerWidth || y >= view.innerHeight) return false;
    const hit = doc.elementFromPoint(x, y);
    return hit === null || region.contains(hit);
  };
  const key = (event: KeyboardEvent) => {
    if (event.key !== "Tab" || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const from = doc.activeElement as HTMLElement | null;
    if (!from || ownsTab(from)) return;
    const stops = tabStops(doc);
    const at = stops.indexOf(from);
    if (at < 0) return;
    const step = event.shiftKey ? -1 : 1;
    const next = stops[at + step];
    if (!next || !region.contains(next) || inView(next)) return;
    for (let index = at + step; index >= 0 && index < stops.length; index += step) {
      const stop = stops[index]!;
      if (!inView(stop)) continue;
      event.preventDefault();
      focusWithRing(stop, { preventScroll: true, focusVisible: true });
      return;
    }
  };
  doc.addEventListener("keydown", key);
  return () => doc.removeEventListener("keydown", key);
}
