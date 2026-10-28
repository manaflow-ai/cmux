// The tray is the composer's sibling, outside its size container. Copy the rendered columns,
// rather than guessing the look's padding or duplicating its responsive breakpoints.
export function followComposerTrayColumns(box: HTMLElement): (() => void) | undefined {
  const dock = box.closest<HTMLElement>(".acpmux-dock");
  const actions = box.querySelector<HTMLElement>(".acpmux-composer-actions");
  const plus = box.querySelector<HTMLElement>(".acpmux-composer-plus .acpmux-picker-button");
  if (!dock || !actions || !plus) return undefined;
  const properties = new Set<string>();
  // The inspector shifts every direct dock child with `translate`, while the
  // dock's parent stays in the pane's original coordinate space.  Rects are
  // visual coordinates, so undo that ancestor translation before deriving the
  // shared margins.  Otherwise the measured surface starts at the shifted
  // edge and the tray receives a second shift through its margin.
  const layoutRect = (node: HTMLElement, stop: HTMLElement): DOMRect => {
    const visual = node.getBoundingClientRect();
    let shift = 0;
    for (let current: HTMLElement | null = node; current && current !== stop; current = current.parentElement) {
      const value = getComputedStyle(current).translate.split(/\s+/)[0];
      if (value && value !== "none") {
        const parsed = Number.parseFloat(value);
        if (Number.isFinite(parsed)) shift += parsed;
      }
    }
    if (!shift) return visual;
    return new DOMRect(visual.left - shift, visual.top, visual.width, visual.height);
  };
  const apply = () => {
    // In inspector/review mode the dock uses display:contents; its parent owns the inline edges.
    const container = getComputedStyle(dock).display === "contents" ? dock.parentElement : dock;
    if (!container) return;
    const surface = layoutRect(box, container);
    const parent = layoutRect(container, container);
    const leading = layoutRect(plus, container);
    const trailing = [...actions.querySelectorAll<HTMLElement>("button")]
      .filter((node) => getComputedStyle(node).visibility !== "hidden")
      .map((node) => layoutRect(node, container))
      .filter((rect) => rect.width > 0 && rect.height > 0)
      .sort((a, b) => b.right - a.right)[0];
    if (!surface.width || !parent.width || !leading.width || !trailing) return;
    const values = {
      "surface-start": surface.left - parent.left,
      "surface-end": parent.right - surface.right,
      "start-inset": leading.left - surface.left,
      "end-inset": surface.right - trailing.right,
      "start-size": leading.width,
      "end-size": trailing.width,
    };
    for (const [name, value] of Object.entries(values)) {
      const property = `--acpmux-tray-${name}`;
      const next = `${value}px`;
      if (dock.style.getPropertyValue(property) !== next) dock.style.setProperty(property, next);
      properties.add(property);
    }
  };
  const resize = new ResizeObserver(apply);
  for (const node of [box, dock, actions, plus]) resize.observe(node);
  if (dock.parentElement) resize.observe(dock.parentElement);
  // Draft/working state can replace the last action without resizing the action cluster.
  const mutation = new MutationObserver(apply);
  mutation.observe(actions, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class", "style", "hidden"],
  });
  apply();
  return () => {
    resize.disconnect();
    mutation.disconnect();
    for (const property of properties) dock.style.removeProperty(property);
  };
}
