// The tray is the composer's sibling, outside its size container. Copy the rendered columns,
// rather than guessing the look's padding or duplicating its responsive breakpoints.
export function followComposerTrayColumns(box: HTMLElement): (() => void) | undefined {
  const dock = box.closest<HTMLElement>(".acpmux-dock");
  const actions = box.querySelector<HTMLElement>(".acpmux-composer-actions");
  const plus = box.querySelector<HTMLElement>(".acpmux-composer-plus .acpmux-picker-button");
  if (!dock || !actions || !plus) return undefined;
  const properties = new Set<string>();
  const apply = () => {
    const surface = box.getBoundingClientRect();
    // In inspector/review mode the dock uses display:contents; its parent owns the inline edges.
    const container = getComputedStyle(dock).display === "contents" ? dock.parentElement : dock;
    if (!container) return;
    const parent = container.getBoundingClientRect();
    const leading = plus.getBoundingClientRect();
    const trailing = [...actions.querySelectorAll<HTMLElement>("button")]
      .filter((node) => getComputedStyle(node).visibility !== "hidden")
      .map((node) => node.getBoundingClientRect())
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
