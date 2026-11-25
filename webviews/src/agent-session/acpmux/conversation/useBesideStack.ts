// The rows beside the bottom stack stay in sight (besideStack.ts): the stack's surfaces' gutters and
// the room outside their top corners, written straight to the scroller's mask variables, no render.
// Read again when the stack, the scroller or a surface changes size, when a surface's own motion
// ends (the tray settling in on its entrance translate), and when the dock's children or a surface's
// `data-card` change (a ghost tray removed; the tray's corners rounding as it turns into a card).
// The stack can also move with no size changing: Session Info pushing the chat over shifts it inside
// a scroller of the same size. So an attribute change on any of the stack's ancestors, and the end of
// an ancestor's own motion, read it again on the next frame (one read per frame at most).
import { useLayoutEffect, type RefObject } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { dockBand } from "../dockBand.experiment";
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
    // Read once per stack: an arm changes with a reload (the gallery's arm, the debug key).
    const arm = experimentArm(dockBand);
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
                card: surface.classList.contains("acpmux-composer-box"),
              };
            })
        : [];
      // The rows run under the card only where its glass frosts them (a see-through window, Lens,
      // Spectrum). An opaque window's card blurs nothing (composerStates.css `--glass-backdrop: none`)
      // and Reduce Transparency draws it solid: under them the rows read sharp through the prompt, so
      // the band stays as it ships (test/agent-pane-dock-band.test.ts).
      const card = dock.querySelector<HTMLElement>(".acpmux-composer-box");
      const frosts = (() => {
        if (arm === "shipped" || !card) return false;
        const style = getComputedStyle(card);
        const blur = style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter");
        return !!blur && blur !== "none";
      })();
      const mask = besideMask(placed, box.width, frosts ? { arm, height: box.height } : undefined);
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
      if (event.target instanceof Element && event.target.matches(SURFACE)) paint();
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
