// A tool output's vertical edges (moreBelow.ts `SCROLLS` and `MORE_BELOW`). Observe only this body;
// streaming a sibling call never walks this output's lines. Changes coalesce into one measurement
// per frame, and scrolling updates the fade immediately without a React render.
import { markScrollEdges } from "./moreBelow";

export function watchOutputViewport(node: HTMLElement): () => void {
  const view = node.ownerDocument.defaultView;
  let frame: number | undefined;
  let alive = true;
  const measure = () => {
    if (alive) markScrollEdges(node);
  };
  const schedule = () => {
    if (frame !== undefined) return;
    if (view?.requestAnimationFrame)
      frame = view.requestAnimationFrame(() => {
        frame = undefined;
        measure();
      });
    else measure();
  };
  const observer = view && new view.MutationObserver(schedule);
  observer?.observe(node, {
    childList: true,
    characterData: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-wrap"],
  });
  const sized = view?.ResizeObserver ? new view.ResizeObserver(schedule) : undefined;
  sized?.observe(node);
  if (node.firstElementChild) sized?.observe(node.firstElementChild);
  node.addEventListener("scroll", measure, { passive: true });
  measure();
  return () => {
    alive = false;
    if (frame !== undefined) view?.cancelAnimationFrame(frame);
    observer?.disconnect();
    sized?.disconnect();
    node.removeEventListener("scroll", measure);
  };
}
