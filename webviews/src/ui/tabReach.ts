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

const TAB_STOPS =
  'a[href], area[href], button, input, select, textarea, iframe, summary, [tabindex], [contenteditable]:not([contenteditable="false"])';

function isTabStop(element: HTMLElement): boolean {
  if (element.tabIndex < 0 || element.closest("[inert]")) return false;
  // `:disabled`, not `.disabled`: a control inside a disabled fieldset (outside its first legend)
  // is disabled too, and the browser neither tabs to it nor lets it take focus.
  if (element.matches(":disabled")) return false;
  return !(element.tagName === "INPUT" && (element as HTMLInputElement).type === "hidden");
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
  const inside = layerStops(layer);
  const edge = event.shiftKey ? inside[0] : inside.at(-1);
  if (!edge || event.target !== edge) return;
  const target = nearestStopOnScreen(layer, event.shiftKey);
  if (!target) return;
  event.preventDefault();
  focusWithRing(target, { preventScroll: true, focusVisible: true });
}

/// Tab or Shift-Tab, from anywhere in the document, whose next stop would be a control in `region`
/// that is not on screen goes on to the nearest stop on screen in that direction instead. The
/// transcript's virtual list mounts rows a little past each edge of the view, and each row's
/// controls are tab stops: from the composer (Shift-Tab), from the control above the rows (Tab),
/// or from the last row in view, the browser's next stop was such a row, and focusing it scrolled
/// the reader away from where they were reading (#38090). With nothing on screen that way, the
/// browser moves focus as usual. A layer that already took the press (the toast deck, Jump to
/// latest) is left alone. Returns the cleanup.
export function keepTabOnScreen(region: HTMLElement): () => void {
  const doc = region.ownerDocument;
  const key = (event: KeyboardEvent) => {
    if (event.key !== "Tab" || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const from = doc.activeElement as HTMLElement | null;
    if (!from) return;
    const stops = tabStops(doc);
    const at = stops.indexOf(from);
    if (at < 0) return;
    const step = event.shiftKey ? -1 : 1;
    const next = stops[at + step];
    if (!next || !region.contains(next) || onScreen(next)) return;
    for (let index = at + step; index >= 0 && index < stops.length; index += step) {
      const stop = stops[index]!;
      if (!onScreen(stop)) continue;
      event.preventDefault();
      focusWithRing(stop, { preventScroll: true, focusVisible: true });
      return;
    }
  };
  doc.addEventListener("keydown", key);
  return () => doc.removeEventListener("keydown", key);
}
