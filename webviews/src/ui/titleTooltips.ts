// Tooltips for plain `title` attributes, for pages (the agent pane) whose controls carry them. A
// native `title` tooltip in a web view waits about a second, draws where the pointer happens to
// be, and can run past the view's edge. Each `title` shows here instead, kept inside the window,
// with the app's hover intent (ui/hoverIntent.ts): the first waits the hover delay, a neighbor's
// then shows at once while the group is warm. The text moves to `data-tooltip`, so the native tooltip never also appears;
// a control with no other name keeps it as its `aria-label`. Controls built on ./Tooltip keep theirs.
// A `data-tooltip-shortcut` shows after the text in the secondary ink, like the native tooltip's;
// a `data-tooltip-detail` on a line under it, also secondary (Fork from here, Claude's).
// A `data-tooltip-side="top"` puts it above the element rather than below (a message's time).
// Text the element cuts off shows in full, as wide as the element (`tooltipWidth`).
import { HOVER_INTENT, HoverGroup, HoverIntent, tooltipGroup, type HoverClock } from "./hoverIntent";

/// Room kept between the tooltip and the window's edges, and its gap from the element.
const EDGE = 6;
/// After a scroll, how long the page stays still before the element under the pointer shows its
/// tooltip: rows passing under a resting pointer show none (at once, each would flash by).
const SCROLL_QUIET = 150;
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
/// there is no room below, and shifted to stay inside the edges. `side` "top" (an element's
/// `data-tooltip-side="top"`: a message's time, as Claude's) puts it above, below only when there
/// is no room above.
export function tooltipPosition(
  anchor: Box,
  size: { width: number; height: number },
  view: { width: number; height: number },
  side: "top" | "bottom" = "bottom",
) {
  const below = anchor.top + anchor.height + GAP;
  const above = anchor.top - GAP - size.height;
  const top =
    side === "top"
      ? above >= EDGE || below + size.height + EDGE > view.height
        ? Math.max(EDGE, above)
        : below
      : below + size.height + EDGE <= view.height
        ? below
        : Math.max(EDGE, above);
  const centered = anchor.left + anchor.width / 2 - size.width / 2;
  const left = Math.min(Math.max(EDGE, centered), Math.max(EDGE, view.width - EDGE - size.width));
  return { left: Math.round(left), top: Math.round(top) };
}

/// Whether `element`'s own text already says `text` (a labeled control): no tooltip then, as
/// #20375 rules (test/tooltip-rules.ts). Text the element cuts off still shows in full.
function repeatsLabel(element: Element, text: string): boolean {
  const own = element.textContent?.replace(/\s+/g, " ").trim().toLowerCase();
  return !!own && own === text.replace(/\s+/g, " ").trim().toLowerCase() && !clips(element);
}

/// Shows `title` and `data-tooltip` text for hovered elements of `doc`. Returns the uninstaller.
/// `options` swap the pages' tooltip group and its timers (tests).
export function installTooltips(
  doc: Document,
  options: { group?: HoverGroup; clock?: HoverClock; delay?: number } = {},
): () => void {
  const win = doc.defaultView;
  if (!win) return () => {};
  const tip = doc.createElement("div");
  // The liquid glass, as every tooltip (ui/Tooltip.tsx; glass.css gives it the tooltip's shadow).
  tip.className = "ui-title-tooltip ui-glass";
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
  // The fade out under way: it ends with the tooltip hidden, unless a show comes first.
  let ending: number | undefined;
  const endFade = () => {
    if (ending !== undefined) win.clearTimeout(ending);
    ending = undefined;
    tip.removeEventListener("transitionend", finishFade);
    tip.removeAttribute("data-ending-style");
  };
  function finishFade(event?: Event) {
    if (event && event.target !== tip) return;
    endFade();
    tip.hidden = true;
  }
  /** The longest of the tooltip's transitions now, in ms (0 with no stylesheet, as in a test page). */
  const fadeMs = () => {
    const times = (value: string) =>
      value
        .split(",")
        .map((part) => part.trim())
        .map((part) => (part.endsWith("ms") ? parseFloat(part) : part.endsWith("s") ? parseFloat(part) * 1000 : 0));
    const style = win.getComputedStyle(tip);
    const durations = times(style.transitionDuration ?? "");
    const delays = times(style.transitionDelay ?? "");
    return Math.max(0, ...durations.map((duration, index) => duration + (delays[index] ?? 0)).filter(Number.isFinite));
  };
  /** Shows `target`'s tooltip: fading in and rising, or at once when `instant` (a warm group's). */
  const show = (instant = true) => {
    if (!target?.isConnected) return;
    const text = textOf(target);
    if (!text) return;
    const shortcut = target.getAttribute("data-tooltip-shortcut");
    const label = doc.createElement("span");
    label.className = "ui-tooltip-text";
    label.textContent = text;
    // A `data-tooltip-detail` says what the control does, on its own line under the text.
    const detail = target.getAttribute("data-tooltip-detail");
    const note = detail ? doc.createElement("span") : undefined;
    if (note) {
      note.className = "ui-tooltip-detail";
      note.textContent = detail;
    }
    // The hint floats to the top right, so it comes first.
    if (shortcut) {
      const hint = doc.createElement("span");
      hint.className = "ui-tooltip-hint";
      hint.textContent = shortcut;
      tip.replaceChildren(hint, label, ...(note ? [note] : []));
    } else tip.replaceChildren(label, ...(note ? [note] : []));
    const anchor = target.getBoundingClientRect();
    const truncated = clips(target);
    const fadeIn = !instant && (tip.hidden === true || ending !== undefined);
    endFade();
    tip.toggleAttribute("data-instant", !fadeIn);
    tip.toggleAttribute("data-starting-style", fadeIn);
    tip.hidden = false;
    // Measured from the window's left: a fixed box still at the last tooltip's place gets only the
    // room right of it, and its text would wrap inside a word ("Chat summar / y").
    tip.style.left = "0px";
    tip.style.top = "0px";
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
    const position = tooltipPosition(
      anchor,
      tip.getBoundingClientRect(),
      { width: doc.documentElement.clientWidth, height: doc.documentElement.clientHeight },
      target.getAttribute("data-tooltip-side") === "top" ? "top" : "bottom",
    );
    tip.style.left = `${position.left}px`;
    tip.style.top = `${position.top}px`;
    if (fadeIn) {
      // The starting style is laid out (measuring did that); dropping it runs the fade in.
      void tip.offsetWidth;
      tip.removeAttribute("data-starting-style");
    }
  };
  // The show waits for the next frame: measuring the tooltip lays out the page, and done at once it
  // landed in the frame of a click that opens a menu (a long frame); a click before then cancels it.
  let frame: number | undefined;
  /** Hides the tooltip: fading out, or at once when `immediately` (a click, a key, a scroll). */
  const hideTip = (immediately = false) => {
    if (frame !== undefined) win.cancelAnimationFrame(frame);
    frame = undefined;
    if (immediately) {
      finishFade();
      return;
    }
    if (tip.hidden || ending !== undefined) return;
    // Fades out (quicker than the fade in), then hides; at once with no transition.
    tip.removeAttribute("data-starting-style");
    tip.setAttribute("data-ending-style", "");
    const ms = fadeMs();
    if (ms <= 0) {
      finishFade();
      return;
    }
    tip.addEventListener("transitionend", finishFade);
    ending = win.setTimeout(finishFade, ms + 50);
  };
  // A hide waits for the next frame, and a show before then cancels it: moving straight from one
  // element to the next (pointerout, then pointerover) swaps the text with no fade out between.
  let hideFrame: number | undefined;
  const requestHide = () => {
    if (frame !== undefined) win.cancelAnimationFrame(frame);
    frame = undefined;
    if (hideFrame !== undefined) return;
    hideFrame = win.requestAnimationFrame(() => {
      hideFrame = undefined;
      hideTip();
    });
  };
  const cancelHide = () => {
    if (hideFrame !== undefined) win.cancelAnimationFrame(hideFrame);
    hideFrame = undefined;
  };
  // The hover delay and the warm group (ui/hoverIntent.ts) decide when `target` shows.
  const intent = new HoverIntent<Element>({
    // A test's clock gets its own group; pages share the one tooltip group.
    group: options.group ?? (options.clock ? new HoverGroup(HOVER_INTENT.tooltipWarm, options.clock) : tooltipGroup),
    clock: options.clock,
    delay: options.delay,
    show: (element, instant) => {
      if (element !== target) return;
      cancelHide();
      if (frame !== undefined) win.cancelAnimationFrame(frame);
      frame = win.requestAnimationFrame(() => {
        frame = undefined;
        show(instant);
      });
    },
    hide: requestHide,
  });
  const hide = () => {
    intent.hover(null);
    requestHide();
    target = undefined;
  };
  let quiet: ReturnType<typeof setTimeout> | undefined;
  // The element under the pointer while a scroll is under way.
  let pending: Element | undefined;
  const onOver = (event: PointerEvent) => {
    if (event.pointerType && event.pointerType !== "mouse") return;
    const element = (event.target as Element | null)?.closest?.("[title], [data-tooltip]") ?? undefined;
    if (quiet !== undefined) {
      pending = element;
      return;
    }
    if (element === target) return;
    const text = element ? textOf(element) : "";
    if (!element || !text || repeatsLabel(element, text)) {
      hide();
      return;
    }
    // Straight from one element to the next: the intent swaps them (at once while warm).
    if (frame !== undefined) win.cancelAnimationFrame(frame);
    frame = undefined;
    target = element;
    intent.hover(element);
  };
  const onOut = (event: PointerEvent) => {
    // Leaving the element (not moving onto one of its children) hides it.
    const into = event.relatedTarget as Node | null;
    if (target && !target.contains(into)) hide();
    if (pending && !pending.contains(into)) pending = undefined;
  };
  // A click, a key, a scroll or the window losing focus puts the tooltip away; the element under
  // the pointer shows it again only once the pointer leaves it and comes back.
  // Only moving from one control to the next keeps tooltips quick, not a click or a scroll.
  const dismiss = () => {
    const under = target;
    intent.dismiss();
    cancelHide();
    // At once, as AppKit's: it does not linger over the menu a click opens or over moving content.
    hideTip(true);
    target = under;
  };
  const onScroll = () => {
    // The first scroll event puts the tooltip away; the rest only push back the end of the scroll.
    if (quiet === undefined) {
      dismiss();
      pending = undefined;
    } else clearTimeout(quiet);
    quiet = setTimeout(() => {
      quiet = undefined;
      const element = pending;
      pending = undefined;
      if (!element?.isConnected || element === target || !textOf(element)) return;
      hide();
      target = element;
      intent.hover(element);
    }, SCROLL_QUIET);
  };
  doc.addEventListener("pointerover", onOver);
  doc.addEventListener("pointerout", onOut);
  doc.addEventListener("pointerdown", dismiss, true);
  doc.addEventListener("keydown", dismiss, true);
  doc.addEventListener("scroll", onScroll, true);
  win.addEventListener("blur", dismiss);
  return () => {
    dismiss();
    intent.dispose();
    doc.removeEventListener("pointerover", onOver);
    doc.removeEventListener("pointerout", onOut);
    doc.removeEventListener("pointerdown", dismiss, true);
    doc.removeEventListener("keydown", dismiss, true);
    doc.removeEventListener("scroll", onScroll, true);
    if (quiet !== undefined) clearTimeout(quiet);
    win.removeEventListener("blur", dismiss);
    endFade();
    tip.remove();
  };
}
