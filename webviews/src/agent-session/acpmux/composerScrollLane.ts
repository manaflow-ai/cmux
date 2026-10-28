// The composer box's trailing actions (Codex's bolt, steer's ↵, Stop, the mic and Send), measured
// onto the box as `--acpmux-actions-width` (composerLocation.css): the prompt in Claude's inline box
// spans the actions' column too, so its scrollbar runs down the box's own right edge, and this width
// is the padding that keeps its text clear of the actions. A box with no actions (or a DOM with no
// layout) keeps the stylesheet's fallback.

/** Keeps `--acpmux-actions-width` on the box around `field` in step with its actions; returns the cleanup. */
export function followActionsWidth(field: HTMLElement): (() => void) | undefined {
  const box = field.closest<HTMLElement>(".acpmux-composer-box");
  const actions = box?.querySelector<HTMLElement>(":scope > .acpmux-chrome-area .acpmux-composer-actions");
  if (!box || !actions) return undefined;
  let last = -1;
  const apply = () => {
    const width = Math.ceil(actions.getBoundingClientRect().width);
    if (width === last) return;
    last = width;
    // The new padding rewraps the draft after this frame's own scrolls ran (a resize observer is
    // told after animation frames): a draft shown to its end, as a paste or typing at the end leaves
    // it, stays at its end.
    const atEnd = field.scrollHeight - field.clientHeight - field.scrollTop <= 1;
    box.style.setProperty("--acpmux-actions-width", `${width}px`);
    if (atEnd) field.scrollTop = field.scrollHeight;
  };
  // The one observer stops with the field (the cleanup below); it reads one box per change.
  const observer = new ResizeObserver(apply);
  observer.observe(actions);
  apply();
  return () => {
    observer.disconnect();
    box.style.removeProperty("--acpmux-actions-width");
  };
}
