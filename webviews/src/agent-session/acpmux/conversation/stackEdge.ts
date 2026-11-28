// The edited-files card's code goes clear under its sticky file name, as macOS 26's scroll edge does under
// a toolbar (Lucas, 2026-11-25: the code read through the name in a see-through window). Chromium, the
// pane's engine, cannot blur the page's own pixels under a backdrop-filter over a see-through window
// (ui/glass/glass.css, CHROMIUM OVER THE WINDOW GLASS), and a fill strong enough to hide the code was a slab.
// So each file's lines fade out where they pass under its name: the body that slides under a stuck name
// carries `data-under` and `--stack-under` (how far it is under, px), and EditedFilesCard.css masks it there.

/// On a file's body while part of it lies under its file name.
export const UNDER_ATTRIBUTE = "data-under";
/// The px of the body under its file name's bottom edge.
export const UNDER_PROPERTY = "--stack-under";

/// How far a body whose top is at `bodyTop` lies under a name whose bottom is at `nameBottom` (one
/// coordinate space), px: 0 while the name is in its place above the body.
export function underName(nameBottom: number, bodyTop: number): number {
  return Math.max(0, Math.round(nameBottom - bodyTop));
}

/// Marks each file body in `stack` that lies under its name, on scroll and on every layout change (a file
/// opened or closed, lines painted, the card resized). Reads every rect first, then writes what changed,
/// once a frame. Returns the remover.
export function installStackEdge(stack: HTMLElement): () => void {
  // A window with no frames (a test DOM) gets nothing.
  if (typeof requestAnimationFrame === "undefined") return () => {};
  let frame = 0;
  const update = () => {
    frame = 0;
    const files = Array.from(stack.querySelectorAll<HTMLElement>(".cv-edit-diff"));
    const marks = files.map((file) => {
      const name = file.querySelector<HTMLElement>(":scope > .cv-edit-diff__header");
      const body = file.querySelector<HTMLElement>(":scope > .cv-edit-diff__body");
      if (!name || !body || body.hidden) return { body, under: 0 };
      return { body, under: underName(name.getBoundingClientRect().bottom, body.getBoundingClientRect().top) };
    });
    for (const { body, under } of marks) {
      if (!body) continue;
      const was = body.style.getPropertyValue(UNDER_PROPERTY);
      if (under > 0) {
        if (was !== `${under}px`) body.style.setProperty(UNDER_PROPERTY, `${under}px`);
        if (!body.hasAttribute(UNDER_ATTRIBUTE)) body.setAttribute(UNDER_ATTRIBUTE, "");
      } else if (was || body.hasAttribute(UNDER_ATTRIBUTE)) {
        body.style.removeProperty(UNDER_PROPERTY);
        body.removeAttribute(UNDER_ATTRIBUTE);
      }
    }
  };
  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(update);
  };
  stack.addEventListener("scroll", schedule, { passive: true });
  const resize = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(schedule);
  const watch = () => {
    if (!resize) return;
    resize.disconnect();
    resize.observe(stack);
    for (const section of Array.from(stack.children)) resize.observe(section);
  };
  watch();
  const sections =
    typeof MutationObserver === "undefined"
      ? null
      : new MutationObserver(() => {
          watch();
          schedule();
        });
  sections?.observe(stack, { childList: true });
  schedule();
  return () => {
    stack.removeEventListener("scroll", schedule);
    resize?.disconnect();
    sections?.disconnect();
    if (frame) cancelAnimationFrame(frame);
  };
}
