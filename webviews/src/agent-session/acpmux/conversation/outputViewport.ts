// A tool output's vertical edge. Observe only this body; streaming a sibling call never walks
// this output's lines. Changes coalesce into one measurement per frame, and scrolling updates
// the fade immediately without a React render.
export function watchOutputViewport(node: HTMLElement, onOverflow: (overflow: boolean) => void): () => void {
  const view = node.ownerDocument.defaultView;
  let frame: number | undefined;
  let alive = true;
  const edge = () => {
    if (!alive) return;
    const height = node.scrollHeight;
    const overflow = height > node.clientHeight + 1;
    node.toggleAttribute("data-more-below", overflow && node.scrollTop + node.clientHeight < height - 1);
  };
  const measure = () => {
    if (!alive) return;
    // Measure the compact cap even while expanded: its own content or width may have changed.
    // Restore the attribute before paint, and discard only these synchronous observer records.
    const expanded = node.dataset.preview === "all";
    const scrollTop = node.scrollTop;
    if (expanded) node.dataset.preview = "cut";
    const overflow = node.scrollHeight > node.clientHeight + 1;
    if (expanded) {
      node.dataset.preview = "all";
      node.scrollTop = scrollTop;
    }
    observer?.takeRecords();
    onOverflow(overflow);
    edge();
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
  node.addEventListener("scroll", edge, { passive: true });
  measure();
  return () => {
    alive = false;
    if (frame !== undefined) view?.cancelAnimationFrame(frame);
    observer?.disconnect();
    sized?.disconnect();
    node.removeEventListener("scroll", edge);
  };
}
