// The composer box's trailing actions (Codex's bolt, steer's ↵, Stop, the mic and Send), measured
// onto the box as `--acpmux-actions-width` (composerLocation.css): the prompt in Claude's inline box
// spans the actions' column too, so its scrollbar runs down the box's own right edge, and this width
// is the padding that keeps its text clear of the actions. A box with no actions (or a DOM with no
// layout) keeps the stylesheet's fallback.
//
// The actions draw over the prompt (raised), so a stale width puts the text under a button and its
// hover or focus pill instead of wrapping (https://github.com/manaflow-ai/cmux/issues/28672). The
// width follows whichever actions element the box holds now (one rendered later, or a new one after
// a remount, is picked up), and it is written again whenever the box no longer carries it.

const ACTIONS = ":scope > .acpmux-chrome-area .acpmux-composer-actions";
const PROPERTY = "--acpmux-actions-width";

/** Keeps `--acpmux-actions-width` on the box around `field` in step with its actions; returns the cleanup. */
export function followActionsWidth(field: HTMLElement): (() => void) | undefined {
  const box = field.closest<HTMLElement>(".acpmux-composer-box");
  if (!box) return undefined;
  let actions: HTMLElement | null = null;
  const apply = () => {
    if (!actions?.isConnected) return;
    const value = `${Math.ceil(actions.getBoundingClientRect().width)}px`;
    if (box.style.getPropertyValue(PROPERTY) === value) return;
    // The new padding rewraps the draft after this frame's own scrolls ran (a resize observer is
    // told after animation frames): a draft shown to its end, as a paste or typing at the end leaves
    // it, stays at its end.
    const atEnd = field.scrollHeight - field.clientHeight - field.scrollTop <= 1;
    box.style.setProperty(PROPERTY, value);
    if (atEnd) field.scrollTop = field.scrollHeight;
  };
  // The one observer stops with the field (the cleanup below); it reads one box per change.
  const observer = new ResizeObserver(apply);
  const follow = () => {
    const now = box.querySelector<HTMLElement>(ACTIONS);
    if (now !== actions) {
      if (actions) observer.unobserve(actions);
      actions = now;
      if (actions) observer.observe(actions);
    }
    apply();
  };
  // The actions element can come after the field, or be replaced; and a write that cleared the
  // box's style (a field leaving the same box) is put back.
  const mutations =
    typeof MutationObserver === "function"
      ? new MutationObserver((records) => {
          // The prompt's own edits (every keystroke) are not the actions'.
          if (records.some((record) => record.target === box || !field.contains(record.target))) follow();
        })
      : undefined;
  mutations?.observe(box, { childList: true, subtree: true, attributes: true, attributeFilter: ["style"] });
  follow();
  return () => {
    observer.disconnect();
    mutations?.disconnect();
    box.style.removeProperty(PROPERTY);
  };
}
