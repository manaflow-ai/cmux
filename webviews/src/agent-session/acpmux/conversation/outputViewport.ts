// A tool output's vertical edge. Observe only this body; streaming a sibling call never walks
// this output's lines. Changes coalesce into one measurement per frame, and scrolling updates
// the fade immediately without a React render.
export function watchOutputViewport(node: HTMLElement, onOverflow: (overflow: boolean) => void): () => void {
  const view = node.ownerDocument.defaultView;
  let frame: number | undefined;
  let alive = true;
  const measure = () => {
    if (!alive) return;
    const overflow = node.scrollHeight > node.clientHeight + 1;
    node.toggleAttribute("data-more-below", overflow && node.scrollTop + node.clientHeight < node.scrollHeight - 1);
    // Keep the measured preview size while it is expanded: collapsing must still offer Show all
    // when a single logical line wrapped past the compact viewport.
    if (node.dataset.preview !== "all") onOverflow(overflow);
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
    attributeFilter: ["data-preview", "data-wrap"],
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
