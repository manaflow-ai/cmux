import type { WidgetTileMount } from "./widgetsClient";

/** Tells the daemon whether `tile` is seen: in view (IntersectionObserver) and its page shown
 * (`visibilitychange`). A state write, not a read: a hidden or scrolled-out widget gets no ticks
 * (`apps.widgets.visible`), and the switch back draws the scene the page kept, with one catch-up
 * tick from the daemon. Returns the stop function. */
export function observeTileVisibility(element: Element, tile: WidgetTileMount): () => void {
  const doc = element.ownerDocument;
  let inView = true;
  const update = () => tile.setVisible(inView && doc.visibilityState !== "hidden");
  const view = doc.defaultView;
  const Observer = view?.IntersectionObserver;
  const observer =
    typeof Observer === "function"
      ? new Observer((entries) => {
          const last = entries[entries.length - 1];
          if (!last) return;
          inView = last.isIntersecting;
          update();
        })
      : undefined;
  observer?.observe(element);
  doc.addEventListener("visibilitychange", update);
  update();
  return () => {
    observer?.disconnect();
    doc.removeEventListener("visibilitychange", update);
  };
}
