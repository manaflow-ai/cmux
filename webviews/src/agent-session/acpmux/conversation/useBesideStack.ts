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
import { experimentSwitchOn, subscribeExperimentSwitches } from "../../../experiments/switches";
import { dockBand } from "../dockBand.experiment";
import { DOCK_NOTICE } from "../noticeSlotModel";
// The asks stack has no surface of its own: a "Needs your input" line and a card. The rows stay in
// sight across its band but for what it draws (besideStack.ts `bandMask`).
import { bandMask, besideMask, clippedRect, joinMasks, type BandHole } from "./besideStack";

const VARIABLES = ["--acpmux-beside-images", "--acpmux-beside-sizes", "--acpmux-beside-positions"] as const;
const SURFACE = ".acpmux-running-tray, .acpmux-composer-box, .acpmux-asks-stack > *";
const ASKS = ":scope > .acpmux-asks-stack";
/// Settings > Advanced > Experiments > See-Through Dock (`experiments.seeThroughDock`, off by default):
/// the asks stack and the dock notices hide only what they draw. Off keeps today's mask, which ends
/// the rows at the stack's top.
export const SEE_THROUGH_DOCK = "seeThroughDock";
/// What a pending ask draws (PendingAsks.tsx): its label, its Dismiss and its card. Any other part of
/// the asks stack (a permission card, the folder trust bar) is drawn whole.
const PENDING_PARTS =
  ".acpmux-pending-ask__label, .acpmux-pending-ask__dismiss, .acpmux-pending-ask > .acpmux-next-step";

/// What `root` draws, as boxes in `box`'s coordinates: each element that paints (a fill, a border, a
/// shadow, glass), each replaced element (an icon, a field), and each line of its words. A notice
/// line with no fill of its own (the switch notice, the managed banner, the host's line) hides the
/// rows behind its words and buttons only, never across its whole width (Leo, 2026-11-17: "why do
/// you have the entire row blanked out? don't ever do that").
const drawn = (root: HTMLElement, box: DOMRect): BandHole[] => {
  const holes: BandHole[] = [];
  const push = (rect: DOMRect, radius: number) => {
    if (rect.width <= 0.25 || rect.height <= 0.25) return;
    holes.push({
      left: rect.left - box.left,
      top: rect.top - box.top,
      right: rect.right - box.left,
      bottom: rect.bottom - box.top,
      radius,
    });
  };
  for (const element of [root, ...root.querySelectorAll<HTMLElement>("*")]) {
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none") continue;
    const background = style.backgroundColor.trim();
    const transparentBackground =
      !background || background === "transparent" || background.endsWith(", 0)") || background.endsWith("/ 0)");
    const paints =
      !transparentBackground ||
      style.backgroundImage !== "none" ||
      style.boxShadow !== "none" ||
      (style.borderStyle !== "none" && style.borderWidth !== "0px") ||
      (!!style.backdropFilter && style.backdropFilter !== "none") ||
      (style.getPropertyValue("-webkit-backdrop-filter") || "none") !== "none" ||
      element.matches("svg, img, input, textarea, select, canvas, video");
    if (paints) push(element.getBoundingClientRect(), Number.parseFloat(style.borderTopLeftRadius) || 0);
  }
  const words = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  for (let node = words.nextNode(); node; node = words.nextNode()) {
    if (!node.textContent?.trim()) continue;
    range.selectNodeContents(node);
    for (const line of range.getClientRects()) push(line, 0);
  }
  range.detach();
  return holes;
};

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
      const seeThrough = experimentSwitchOn(SEE_THROUGH_DOCK);
      // bottomStack.css passes the pointer through the asks stack's room only while its rows show.
      dock.toggleAttribute("data-see-through", seeThrough);
      const asks = over && seeThrough ? dock.querySelector<HTMLElement>(ASKS) : null;
      let band: ReturnType<typeof bandMask>;
      if (asks) {
        const area = asks.getBoundingClientRect();
        const holes: BandHole[] = [];
        for (const part of asks.children) {
          if (!part.classList.contains("acpmux-pending-ask")) {
            holes.push(...drawn(part as HTMLElement, box));
            continue;
          }
          // A leaving ask keeps its card laid out while `useFold` shrinks the section and clips it.
          // The card's own rect still reports its full height during that motion, so using it as a
          // hole would hide the transcript below the visible part of the card and blank the rest of
          // the row. Clip every pending part to the section that actually paints it.
          const visible = part.getBoundingClientRect();
          for (const element of part.querySelectorAll<HTMLElement>(PENDING_PARTS)) {
            const rect = clippedRect(element.getBoundingClientRect(), visible);
            if (!rect) continue;
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
      const notices = over && seeThrough ? [...dock.querySelectorAll<HTMLElement>(DOCK_NOTICE)] : [];
      let noticeMask: ReturnType<typeof bandMask>;
      for (const notice of notices) {
        const area = notice.getBoundingClientRect();
        const holes = drawn(notice, box);
        noticeMask = joinMasks(
          noticeMask,
          bandMask({ top: area.top - box.top, bottom: Math.min(area.bottom, box.bottom) - box.top, holes }, box.width),
        );
      }
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
      const mask = joinMasks(
        joinMasks(besideMask(placed, box.width, frosts ? { arm, height: box.height } : undefined), band),
        noticeMask,
      );
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
    // The person flips See-Through Dock in Settings: the mask follows at once.
    const unsubscribeSwitches = subscribeExperimentSwitches(nextFrame);
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
      unsubscribeSwitches();
      dock.removeAttribute("data-see-through");
      document.removeEventListener("animationend", ancestorSettled);
      document.removeEventListener("transitionend", ancestorSettled);
      for (const name of VARIABLES) view.style.removeProperty(name);
    };
  }, [dock, scroller, ghostClass]);
}
