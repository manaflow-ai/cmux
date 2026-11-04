// A send is one change between two known layouts (leo-workspace design/motion.md, Leo 2026-11-04:
// "since we fucking know what's gonna happen, we move all our affected, possibly affected elements
// in the cohesive way"). From an empty chat the hero and the recent-chat lists leave as the first
// rows come in: the rows fade in at their final size (`cv-message-enter`, `--agent-motion-in`) and
// what left fades out on that same clock from where it was drawn, instead of vanishing in the frame
// the transcript replaces it.
//
// What fades out is an inert copy (aria-hidden, inert, no pointer events) laid over the pane at the
// old element's box: the live view underneath is already the new one, takes input and streams.
// Cost: one clone and one rect read per leaving element, once per first send. Stop condition: each
// copy's animation is finite (`--agent-motion-in`); it is removed on finish or cancel, and nothing is
// copied with motion off, under Reduce Motion or while the page is away.
import { entranceAllowed } from "../shared/pageReveal";
import { cssTimeMs } from "./conversation/fold";

/// What a new chat's empty state draws that the first send removes: the hero and the lists above
/// the composer.
export const EMPTY_STATE_LEAVING = [".acpmux-empty", ".acpmux-home-area"] as const;

export type LeavingCopy = { copy: HTMLElement; rect: DOMRect };

function motionAllowed(node: Element): boolean {
  const view = node.ownerDocument.defaultView;
  if (!view || view.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return false;
  return entranceAllowed(node.ownerDocument);
}

/// Copies of the elements under `root` matching `selectors`, with the boxes they are drawn at now.
/// Read before the change commits (the old elements are still in the document). None when motion
/// is off.
export function captureLeaving(root: HTMLElement | null, selectors: readonly string[]): LeavingCopy[] {
  if (!root || !motionAllowed(root)) return [];
  const copies: LeavingCopy[] = [];
  for (const selector of selectors) {
    const node = root.querySelector<HTMLElement>(selector);
    if (!node) continue;
    const rect = node.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) continue;
    const copy = node.cloneNode(true) as HTMLElement;
    copy.setAttribute("aria-hidden", "true");
    copy.setAttribute("inert", "");
    copy.dataset.sendLeaving = "";
    for (const named of [copy, ...copy.querySelectorAll<HTMLElement>("[id]")]) named.removeAttribute("id");
    copies.push({ copy, rect });
  }
  return copies;
}

/// Lays `copies` over `root` at their old boxes and fades them out on the rows' entrance clock
/// (`--agent-motion-in`, `--agent-ease-out`), removing each when its fade ends.
export function fadeOutLeaving(root: HTMLElement | null, copies: readonly LeavingCopy[]): void {
  if (!root || copies.length === 0) return;
  const style = root.ownerDocument.defaultView?.getComputedStyle(root);
  const duration = cssTimeMs(style?.getPropertyValue("--agent-motion-in") ?? "") ?? 0;
  const easing = style?.getPropertyValue("--agent-ease-out").trim() || "ease-out";
  if (!(duration > 0) || !motionAllowed(root)) return;
  for (const { copy, rect } of copies) {
    Object.assign(copy.style, {
      position: "absolute",
      margin: "0",
      boxSizing: "border-box",
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      maxHeight: "none",
      pointerEvents: "none",
      zIndex: "1",
    });
    root.append(copy);
    // Placed against the box it is positioned in (its offset parent), so the copy lands on the
    // pixels the element left.
    const base = (copy.offsetParent ?? root).getBoundingClientRect();
    copy.style.left = `${rect.left - base.left}px`;
    copy.style.top = `${rect.top - base.top}px`;
    if (typeof copy.animate !== "function") {
      copy.remove();
      continue;
    }
    const fade = copy.animate([{ opacity: 1 }, { opacity: 0 }], { duration, easing, fill: "forwards" });
    const done = () => copy.remove();
    fade.onfinish = done;
    fade.oncancel = done;
  }
}
