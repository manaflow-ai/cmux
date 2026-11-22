// The rows beside the bottom stack stay in sight (besideStack.ts): the stack's surfaces' gutters and
// the room outside their top corners, written straight to the scroller's mask variables, no render.
// Read again when the stack, the scroller or a surface changes size, when a surface's own motion
// ends (the tray settling in on its entrance translate), and when the dock's children or a surface's
// `data-card` change (a ghost tray removed; the tray's corners rounding as it turns into a card).
// The stack can also move with no size changing: Session Info pushing the chat over shifts it inside
// a scroller of the same size. So an attribute change on any of the stack's ancestors, and the end of
// an ancestor's own motion, read it again on the next frame (one read per frame at most).
// The asks stack's pinned cards ("Needs your input", PendingAsks.tsx; a sub-session's ask, ChildAsk.tsx)
// are surfaces too, and the stack's gaps under them paint nothing (besideStack.ts `clearTo`): the
// transcript stays in sight beside and between them, as it does beside the composer card (Leo,
// 2026-11-17: "this needs your input dismiss row erases things behind it").
import { useLayoutEffect, type RefObject } from "react";
import { besideMask } from "./besideStack";

const VARIABLES = ["--acpmux-beside-images", "--acpmux-beside-sizes", "--acpmux-beside-positions"] as const;
/// A pinned ask's card: the part of its section under the "Needs your input" line.
const ASK_CARD = ".acpmux-asks-stack > .acpmux-pending-ask > :not(.acpmux-pending-ask__head)";
/// The stack's surfaces, the asks stack's cards with the tray and the composer card.
export const SURFACE = `.acpmux-running-tray, .acpmux-composer-box, ${ASK_CARD}`;
/// What a surface's own motion plays on: a surface, or a pinned ask's section (its entrance, its fold).
const MOVES = `${SURFACE}, .acpmux-asks-stack > .acpmux-pending-ask`;

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
    const surfaces = () =>
      dock.querySelectorAll<HTMLElement>(`:scope > .acpmux-running-tray, .acpmux-composer-box, :scope > ${ASK_CARD}`);
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
              // A pinned ask's card is drawn only inside its section (which clips it while it folds
              // out) and the asks stack (its own scroller); the stack's room under it paints nothing.
              const asks = surface.matches(ASK_CARD) ? surface.closest(".acpmux-asks-stack") : null;
              const section = asks ? surface.parentElement : null;
              const stack = asks?.getBoundingClientRect();
              const stackBottom = stack ? Math.min(stack.bottom, box.bottom) : box.bottom;
              const drawnBottom = Math.min(
                rect.bottom,
                section?.getBoundingClientRect().bottom ?? rect.bottom,
                stackBottom,
              );
              return {
                left: rect.left - box.left,
                top: Math.max(rect.top, stack?.top ?? rect.top) - box.top,
                right: rect.right - box.left,
                bottom: drawnBottom - box.top,
                radiusLeft: Number.parseFloat(style.borderTopLeftRadius) || 0,
                radiusRight: Number.parseFloat(style.borderTopRightRadius) || 0,
                ...(asks && { clearTo: stackBottom - box.top }),
              };
            })
        : [];
      const mask = besideMask(placed, box.width);
      const values = [mask?.images, mask?.sizes, mask?.positions];
      VARIABLES.forEach((name, at) => {
        const value = values[at];
        if (value === (view.style.getPropertyValue(name) || undefined)) return;
        if (value) view.style.setProperty(name, value);
        else view.style.removeProperty(name);
      });
    };
    let frame = 0;
    const nextFrame = () => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        paint();
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
      if (event.target instanceof Element && event.target.matches(MOVES)) paint();
    };
    dock.addEventListener("animationend", settled);
    dock.addEventListener("transitionend", settled);
    // The stack's ancestors (the scroller writes its own mask variables, so it is never one here).
    const moved = new MutationObserver(nextFrame);
    for (let node = dock.parentElement; node; node = node.parentElement)
      if (node !== view) moved.observe(node, { attributes: true });
    const ancestorSettled = (event: Event) => {
      if (event.target instanceof Node && event.target !== dock && event.target.contains(dock)) nextFrame();
    };
    document.addEventListener("animationend", ancestorSettled);
    document.addEventListener("transitionend", ancestorSettled);
    paint();
    return () => {
      sizes.disconnect();
      children.disconnect();
      cards.disconnect();
      moved.disconnect();
      if (frame) cancelAnimationFrame(frame);
      dock.removeEventListener("animationend", settled);
      dock.removeEventListener("transitionend", settled);
      document.removeEventListener("animationend", ancestorSettled);
      document.removeEventListener("transitionend", ancestorSettled);
      for (const name of VARIABLES) view.style.removeProperty(name);
    };
  }, [dock, scroller, ghostClass]);
}
