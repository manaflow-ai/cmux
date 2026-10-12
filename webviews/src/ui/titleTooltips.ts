// Tooltips for plain `title` attributes, for pages (the agent pane) whose controls carry them. A
// native `title` tooltip in a web view waits about a second, draws where the pointer happens to
// be, and can run past the view's edge. Each `title` shows here instead: at once, with no hover
// delay (POLISH), and kept inside the window. The text moves to `data-tooltip`, so the native tooltip never also appears;
// a control with no other name keeps it as its `aria-label`. Controls built on ./Tooltip keep theirs.
// A `data-tooltip-shortcut` shows after the text in the secondary ink, like the native tooltip's.
// Text the element cuts off shows in full, as wide as the element (`tooltipWidth`).

/// Room kept between the tooltip and the window's edges, and its gap from the element.
const EDGE = 6;
const GAP = 6;

type Box = { left: number; top: number; width: number; height: number };

/// The standard tooltip's widest, the native one's (TooltipPanel.maxWidth).
const MAX_WIDTH = 320;
/// The narrowest a truncated element's tooltip may wrap at, so a cut-off chip's text is not a column.
const TRUNCATED_MIN_MAX = 480;

/// The tooltip's min and max width for an element `width` px wide in a `view` px window. A tooltip
/// for text the element cuts off shows it in full, wrapping, up to the element's width (at least
/// 480 px) and never narrower than the element's line, unless the full text (`text`, its width on
/// one line) is shorter: then it is just the text's width. Any other tooltip wraps at 320 px. Both
/// stay inside the window's edges.
export function tooltipWidth({
  width,
  truncated,
  view,
  text,
}: {
  width: number;
  truncated: boolean;
  view: number;
  text?: number;
}) {
  const room = Math.max(0, view - 2 * EDGE);
  if (!truncated) return { min: 0, max: Math.min(MAX_WIDTH, room) };
  const line = Math.ceil(width);
  const min = text === undefined ? line : Math.min(line, Math.ceil(text));
  return { min: Math.min(min, room), max: Math.min(Math.max(line, TRUNCATED_MIN_MAX), room) };
}

/// Whether `element` or anything inside it cuts its text off: a row can carry the title while its
/// label clips (BranchBasePicker's rows).
function clips(element: Element): boolean {
  const cut = (node: Element) => node.scrollWidth > node.clientWidth + 1;
  if (cut(element)) return true;
  for (const child of element.querySelectorAll("*")) if (cut(child)) return true;
  return false;
}

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
    if (!target?.isConnected) return;
    const text = textOf(target);
    if (!text) return;
    const shortcut = target.getAttribute("data-tooltip-shortcut");
    const label = doc.createElement("span");
    label.className = "ui-tooltip-text";
    label.textContent = text;
    // The hint floats to the top right, so it comes first.
    if (shortcut) {
      const hint = doc.createElement("span");
      hint.className = "ui-tooltip-hint";
      hint.textContent = shortcut;
      tip.replaceChildren(hint, label);
    } else tip.replaceChildren(label);
    const anchor = target.getBoundingClientRect();
    const truncated = clips(target);
    tip.hidden = false;
    let natural: number | undefined;
    if (truncated) {
      // The full text's width on one line, so a short title gets no wide empty box.
      tip.style.minWidth = "0";
      tip.style.maxWidth = "none";
      // Zero means no layout to measure (a detached or unrendered page): keep the line's width.
      natural = tip.getBoundingClientRect().width || undefined;
    }
    const width = tooltipWidth({
      width: anchor.width,
      truncated,
      view: doc.documentElement.clientWidth,
      text: natural,
    });
    tip.style.minWidth = `${width.min}px`;
    tip.style.maxWidth = `${width.max}px`;
    const position = tooltipPosition(anchor, tip.getBoundingClientRect(), {
      width: doc.documentElement.clientWidth,
      height: doc.documentElement.clientHeight,
    });
    tip.style.left = `${position.left}px`;
    tip.style.top = `${position.top}px`;
  };
  const hide = () => {
    tip.hidden = true;
    target = undefined;
  };
  const onOver = (event: PointerEvent) => {
    if (event.pointerType && event.pointerType !== "mouse") return;
    const element = (event.target as Element | null)?.closest?.("[title], [data-tooltip]") ?? undefined;
    if (element === target) return;
    hide();
    if (!element || !textOf(element)) return;
    target = element;
    show();
  };
  const onOut = (event: PointerEvent) => {
    // Leaving the element (not moving onto one of its children) hides it.
    if (target && !target.contains(event.relatedTarget as Node | null)) hide();
  };
  // A click, a key, a scroll or the window losing focus puts the tooltip away; the element under
  // the pointer shows it again only once the pointer leaves it and comes back.
  const dismiss = () => {
    const under = target;
    hide();
    target = under;
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
