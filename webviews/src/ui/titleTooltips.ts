// Tooltips for plain `title` attributes, for pages (the agent pane) whose controls carry them. A
// native `title` tooltip in a web view waits about a second, draws where the pointer happens to
// be, and can run past the view's edge. Each `title` shows here instead: after a short hover, at
// once when the pointer moves on from a tooltip just shown (along a rail or a toolbar), and kept
// inside the window. The text moves to `data-tooltip`, so the native tooltip never also appears;
// a control with no other name keeps it as its `aria-label`. Controls built on ./Tooltip keep theirs.

/// Hover time before the first tooltip.
export const TOOLTIP_DELAY = 500;
/// How long after one hides the next shows without the delay.
export const TOOLTIP_WARM = 400;
/// Room kept between the tooltip and the window's edges, and its gap from the element.
const EDGE = 6;
const GAP = 6;

type Box = { left: number; top: number; width: number; height: number };

/// Where a `size` tooltip for `anchor` goes in a `view` window: below and centered, above when
/// there is no room below, and shifted to stay inside the edges.
export function tooltipPosition(
  anchor: Box,
  size: { width: number; height: number },
  view: { width: number; height: number },
) {
  const below = anchor.top + anchor.height + GAP;
  const top = below + size.height + EDGE <= view.height ? below : Math.max(EDGE, anchor.top - GAP - size.height);
  const centered = anchor.left + anchor.width / 2 - size.width / 2;
  const left = Math.min(Math.max(EDGE, centered), Math.max(EDGE, view.width - EDGE - size.width));
  return { left: Math.round(left), top: Math.round(top) };
}

/// Shows `title` and `data-tooltip` text for hovered elements of `doc`. Returns the uninstaller.
export function installTooltips(doc: Document): () => void {
  const win = doc.defaultView;
  if (!win) return () => {};
  const tip = doc.createElement("div");
  tip.className = "ui-title-tooltip";
  tip.setAttribute("role", "tooltip");
  tip.hidden = true;
  doc.body.append(tip);
  let target: Element | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let hiddenAt = Number.NEGATIVE_INFINITY;

  const textOf = (element: Element) => {
    // A title React set or changed since the last hover moves over first.
    const title = element.getAttribute("title");
    if (title !== null) {
      element.removeAttribute("title");
      // The title may have been the control's only name (an icon button).
      if (title && !element.hasAttribute("aria-label") && !element.textContent?.trim())
        element.setAttribute("aria-label", title);
      if (title) element.setAttribute("data-tooltip", title);
      else element.removeAttribute("data-tooltip");
    }
    return element.getAttribute("data-tooltip") ?? "";
  };
  const show = () => {
    timer = undefined;
    if (!target?.isConnected) return;
    const text = textOf(target);
    if (!text) return;
    tip.textContent = text;
    tip.hidden = false;
    const position = tooltipPosition(target.getBoundingClientRect(), tip.getBoundingClientRect(), {
      width: doc.documentElement.clientWidth,
      height: doc.documentElement.clientHeight,
    });
    tip.style.left = `${position.left}px`;
    tip.style.top = `${position.top}px`;
  };
  const hide = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (!tip.hidden) hiddenAt = performance.now();
    tip.hidden = true;
    target = undefined;
  };
  const onOver = (event: PointerEvent) => {
    if (event.pointerType && event.pointerType !== "mouse") return;
    const element = (event.target as Element | null)?.closest?.("[title], [data-tooltip]") ?? undefined;
    if (element === target) return;
    const warm = !tip.hidden || performance.now() - hiddenAt < TOOLTIP_WARM;
    hide();
    if (!element || !textOf(element)) return;
    target = element;
    if (warm) show();
    else timer = setTimeout(show, TOOLTIP_DELAY);
  };
  const onOut = (event: PointerEvent) => {
    // Leaving the element (not moving onto one of its children) hides it.
    if (target && !target.contains(event.relatedTarget as Node | null)) hide();
  };
  // A click, a key, a scroll or the window losing focus puts the tooltip away, and the next
  // one waits again.
  const dismiss = () => {
    hide();
    hiddenAt = Number.NEGATIVE_INFINITY;
  };
  doc.addEventListener("pointerover", onOver);
  doc.addEventListener("pointerout", onOut);
  doc.addEventListener("pointerdown", dismiss, true);
  doc.addEventListener("keydown", dismiss, true);
  doc.addEventListener("scroll", dismiss, true);
  win.addEventListener("blur", dismiss);
  return () => {
    dismiss();
    doc.removeEventListener("pointerover", onOver);
    doc.removeEventListener("pointerout", onOut);
    doc.removeEventListener("pointerdown", dismiss, true);
    doc.removeEventListener("keydown", dismiss, true);
    doc.removeEventListener("scroll", dismiss, true);
    win.removeEventListener("blur", dismiss);
    tip.remove();
  };
}
