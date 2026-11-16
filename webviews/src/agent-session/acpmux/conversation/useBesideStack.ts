// The rows beside the bottom stack stay in sight (besideStack.ts): the stack's surfaces' gutters and
// the room outside their top corners, written straight to the scroller's mask variables, no render.
// Read again when the stack, the scroller or a surface changes size, when a surface's own motion
// ends (the tray settling in on its entrance translate), and when the dock's children or a surface's
// `data-card` change (a ghost tray removed; the tray's corners rounding as it turns into a card).
import { useLayoutEffect, type RefObject } from "react";
import { besideMask } from "./besideStack";

const VARIABLES = ["--acpmux-beside-images", "--acpmux-beside-sizes", "--acpmux-beside-positions"] as const;
const SURFACE = ".acpmux-running-tray, .acpmux-composer-box";

/// Keeps `scroller`'s beside-the-stack mask layers on `dock`'s surfaces. `ghostClass` marks the copy
/// of a tray that left, which takes no room.
export function useBesideStack(
  dock: HTMLElement | null | undefined,
  scroller: RefObject<HTMLElement | null>,
  ghostClass: string,
) {
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!dock || !view) return;
    const surfaces = () => dock.querySelectorAll<HTMLElement>(`:scope > .acpmux-running-tray, .acpmux-composer-box`);
    const paint = () => {
      const box = view.getBoundingClientRect();
      const stack = dock.getBoundingClientRect();
      // A stack in the flow under the view (or with no box) reaches over no row.
      const over = stack.height > 0 && stack.top < box.bottom;
      const placed = over
        ? [...surfaces()]
            .filter((surface) => !surface.classList.contains(ghostClass))
            .map((surface) => {
              const rect = surface.getBoundingClientRect();
              const style = getComputedStyle(surface);
              return {
                left: rect.left - box.left,
                top: rect.top - box.top,
                right: rect.right - box.left,
                bottom: Math.min(rect.bottom, box.bottom) - box.top,
                radiusLeft: Number.parseFloat(style.borderTopLeftRadius) || 0,
                radiusRight: Number.parseFloat(style.borderTopRightRadius) || 0,
              };
            })
        : [];
      const mask = besideMask(placed, box.width);
      const values = [mask?.images, mask?.sizes, mask?.positions];
      VARIABLES.forEach((name, at) => {
        const value = values[at];
        if (value) view.style.setProperty(name, value);
        else view.style.removeProperty(name);
      });
    };
    const sizes = new ResizeObserver(paint);
    // A new surface (a tray that opens) is sized from its first frame; a ghost tray removed frees
    // the room it held.
    const children = new MutationObserver(() => {
      for (const surface of surfaces()) sizes.observe(surface);
      paint();
    });
    // The tray's corners round as it turns into a card (`data-card`): rare, so the whole dock's.
    const cards = new MutationObserver(paint);
    sizes.observe(dock);
    sizes.observe(view);
    for (const surface of surfaces()) sizes.observe(surface);
    children.observe(dock, { childList: true });
    cards.observe(dock, { attributes: true, attributeFilter: ["data-card"], subtree: true });
    // Only a surface's own motion moves it; the composer's hovers and the tray's count rolls do not.
    const settled = (event: Event) => {
      if (event.target instanceof Element && event.target.matches(SURFACE)) paint();
    };
    dock.addEventListener("animationend", settled);
    dock.addEventListener("transitionend", settled);
    paint();
    return () => {
      sizes.disconnect();
      children.disconnect();
      cards.disconnect();
      dock.removeEventListener("animationend", settled);
      dock.removeEventListener("transitionend", settled);
      for (const name of VARIABLES) view.style.removeProperty(name);
    };
  }, [dock, scroller, ghostClass]);
}
