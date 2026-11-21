// The rows beside the bottom stack stay in sight (besideStack.ts): the stack's surfaces' gutters and
// the room outside their top corners, written straight to the scroller's mask variables, no render.
// Read again when the stack, the scroller or a surface changes size, when a surface's own motion
// ends (the tray settling in on its entrance translate), and when the dock's children or a surface's
// `data-card` change (a ghost tray removed; the tray's corners rounding as it turns into a card).
// The stack can also move with no size changing: Session Info pushing the chat over shifts it inside
// a scroller of the same size. So an attribute change on any of the stack's ancestors, and the end of
// an ancestor's own motion, read it again on the next frame (one read per frame at most).
import { useLayoutEffect, type RefObject } from "react";
// The asks stack has no surface of its own: a "Needs your input" line and a card. The rows stay in
// sight across its band but for what it draws (besideStack.ts `bandMask`).
import { bandMask, besideMask, joinMasks, type BandHole } from "./besideStack";

const VARIABLES = ["--acpmux-beside-images", "--acpmux-beside-sizes", "--acpmux-beside-positions"] as const;
const SURFACE = ".acpmux-running-tray, .acpmux-composer-box, .acpmux-asks-stack > *";
const ASKS = ":scope > .acpmux-asks-stack";
/// What a pending ask draws (PendingAsks.tsx): its label, its Dismiss and its card. Any other part of
/// the asks stack (a permission card, the folder trust bar) is drawn whole.
const PENDING_PARTS =
  ".acpmux-pending-ask__label, .acpmux-pending-ask__dismiss, .acpmux-pending-ask > .acpmux-next-step";

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
      const asks = over ? dock.querySelector<HTMLElement>(ASKS) : null;
      let band: ReturnType<typeof bandMask>;
      if (asks) {
        const area = asks.getBoundingClientRect();
        const holes: BandHole[] = [];
        for (const part of asks.children) {
          const drawn = part.classList.contains("acpmux-pending-ask")
            ? [...part.querySelectorAll<HTMLElement>(PENDING_PARTS)]
            : [part as HTMLElement];
          for (const element of drawn) {
            const rect = element.getBoundingClientRect();
            holes.push({
              left: rect.left - box.left,
              top: rect.top - box.top,
              right: rect.right - box.left,
              bottom: rect.bottom - box.top,
              radius: Number.parseFloat(getComputedStyle(element).borderTopLeftRadius) || 0,
            });
          }
        }
        band = bandMask(
          { top: area.top - box.top, bottom: Math.min(area.bottom, box.bottom) - box.top, holes },
          box.width,
        );
      }
      const mask = joinMasks(besideMask(placed, box.width), band);
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
      observeParts();
      paint();
    });
    // The asks stack's parts come and go inside it (an ask answered or dismissed), so its subtree's
    // children are watched as well, and each of its parts is sized.
    const observeParts = () => {
      for (const surface of surfaces()) sizes.observe(surface);
      const asks = dock.querySelector<HTMLElement>(ASKS);
      if (!asks) return;
      sizes.observe(asks);
      for (const part of asks.children) sizes.observe(part);
      children.observe(asks, { childList: true });
    };
    // The tray's corners round as it turns into a card (`data-card`): rare, so the whole dock's.
    const cards = new MutationObserver(paint);
    sizes.observe(dock);
    sizes.observe(view);
    observeParts();
    children.observe(dock, { childList: true });
    cards.observe(dock, { attributes: true, attributeFilter: ["data-card"], subtree: true });
    // Only a surface's own motion moves it; the composer's hovers and the tray's count rolls do not.
    const settled = (event: Event) => {
      if (event.target instanceof Element && event.target.matches(SURFACE)) paint();
    };
    dock.addEventListener("animationend", settled);
    dock.addEventListener("transitionend", settled);
    // The asks stack scrolls inside its own height in a short pane: its parts move with no size changing.
    dock.addEventListener("scroll", nextFrame, true);
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
      dock.removeEventListener("scroll", nextFrame, true);
      document.removeEventListener("animationend", ancestorSettled);
      document.removeEventListener("transitionend", ancestorSettled);
      for (const name of VARIABLES) view.style.removeProperty(name);
    };
  }, [dock, scroller, ghostClass]);
}
