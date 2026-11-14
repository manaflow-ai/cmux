// Tooltips for plain `title` attributes, for pages (the agent pane) whose controls carry them. A
// native `title` tooltip in a web view waits about a second, draws where the pointer happens to
// be, and can run past the view's edge. Each `title` shows here instead, kept inside the window,
// with the app's hover intent (ui/hoverIntent.ts): the first waits the hover delay, a neighbor's
// then shows at once while the group is warm. The text moves to `data-tooltip`, so the native tooltip never also appears;
// a control with no other name keeps it as its `aria-label`. Controls built on ./Tooltip keep theirs.
// A `data-tooltip-shortcut` shows after the text in the secondary ink, like the native tooltip's;
// a `data-tooltip-detail` on a line under it, also secondary (Fork from here, Claude's).
// Above by default; `data-tooltip-side="bottom"` prefers below, "left" the side of its popup.
// It anchors at what the element draws, not its whole box: a row as wide as the pane shows its
// tooltip at its words, not over its middle. A `data-tooltip-anchor` (a selector) names that part.
// It stays inside the scrolling region the element is in (the transcript), and out of a band the host
// draws over (`data-tooltip-covered`: the agent pane's tab row, under the native tabs), so a row
// near the top flips below rather than clipping under the tabs; a popup's row may leave its popup,
// which floats over the pane.
// Text the element cuts off shows in full, wrapping in the same compact bubble.
import { HOVER_INTENT, HoverGroup, HoverIntent, tooltipGroup, type HoverClock } from "./hoverIntent";
import { PointerMotion } from "./pointerMotion";
import { UI_TOOLTIP_GAP, UI_TOOLTIP_EDGE, UI_TOOLTIP_MAX_WIDTH, tooltipScale } from "./tooltipTokens";
import { onPopupInsetChange, popupInsetOf } from "./popupInset";
export { UI_TOOLTIP_EDGE, UI_TOOLTIP_MAX_WIDTH } from "./tooltipTokens";

/// A scrolling row must settle before its tooltip opens under a resting pointer.
const SCROLL_QUIET = 150;

type Box = { left: number; top: number; width: number; height: number };

/// A full label wraps inside the compact bubble; its source row never forces an empty wide box.
export function tooltipWidth({
  view,
  scale = 1,
}: {
  width: number;
  truncated: boolean;
  view: number;
  text?: number;
  scale?: number;
}) {
  return {
    min: 0,
    max: Math.min(UI_TOOLTIP_MAX_WIDTH * scale, Math.max(0, view - 2 * UI_TOOLTIP_EDGE * scale)),
  };
}

/// Whether `element` or anything inside it cuts its text off: a row can carry the title while its
/// label clips (BranchBasePicker's rows).
function clips(element: Element): boolean {
  const cut = (node: Element) => node.scrollWidth > node.clientWidth + 1;
  if (cut(element)) return true;
  for (const child of element.querySelectorAll("*")) if (cut(child)) return true;
  return false;
}

/// Where a `size` tooltip for `anchor` goes in a `view` window: above and centered by default, below
/// when there is no room above, and shifted to stay inside the edges. `side` "top" (the default,
/// and an element's `data-tooltip-side="top"`) puts it above, below only when there is no room above.
/// `bounds` (the element's scrolling region, `boundsOf`) is where it goes when it fits there above
/// or below the anchor; else the window's edges, as before.
export function tooltipPosition(
  anchor: Box,
  size: { width: number; height: number },
  view: { width: number; height: number },
  side: "top" | "bottom" | "left" = "top",
  scale = 1,
  bounds?: Box,
) {
  const gap = UI_TOOLTIP_GAP * scale;
  const edge = UI_TOOLTIP_EDGE * scale;
  const fits = (area: Box) =>
    size.width + 2 * edge <= area.width &&
    (anchor.top - gap - size.height >= area.top + edge ||
      anchor.top + anchor.height + gap + size.height + edge <= area.top + area.height);
  const area = bounds && fits(bounds) ? bounds : { left: 0, top: 0, width: view.width, height: view.height };
  const minLeft = area.left + edge;
  const minTop = area.top + edge;
  const right = area.left + area.width;
  const bottom = area.top + area.height;
  if (side === "left") {
    const before = anchor.left - gap - size.width;
    const after = anchor.left + anchor.width + gap;
    const left = before >= minLeft ? before : after + size.width + edge <= right ? after : undefined;
    if (left !== undefined) {
      const top = Math.min(
        Math.max(minTop, anchor.top + (anchor.height - size.height) / 2),
        Math.max(minTop, bottom - edge - size.height),
      );
      return { left: Math.round(left), top: Math.round(top) };
    }
  }
  // Below an anchor above the bounds' top (a header control over an open Find bar) starts at that top.
  const below = Math.max(minTop, anchor.top + anchor.height + gap);
  const above = anchor.top - gap - size.height;
  const top =
    side !== "bottom"
      ? above >= minTop || below + size.height + edge > bottom
        ? Math.max(minTop, above)
        : below
      : below + size.height + edge <= bottom
        ? below
        : Math.max(minTop, above);
  const centered = anchor.left + anchor.width / 2 - size.width / 2;
  const left = Math.min(Math.max(minLeft, centered), Math.max(minLeft, right - edge - size.width));
  return { left: Math.round(left), top: Math.round(top) };
}

/// The part of `box` that `element` draws: the box of its contents (a pane-wide row's icon, words
/// and chevron), cut to the element, at the element's own height. The element's box when it draws
/// nothing measurable (an empty control, a page without range geometry).
function drawnBox(element: Element, box: DOMRect): Box {
  const range = element.ownerDocument.createRange?.();
  if (!range || typeof range.getBoundingClientRect !== "function") return box;
  range.selectNodeContents(element);
  const drawn = range.getBoundingClientRect();
  range.detach?.();
  const left = Math.max(box.left, drawn.left);
  const right = Math.min(box.right, drawn.right);
  if (!(drawn.width > 0) || right <= left) return box;
  return { left, top: box.top, width: right - left, height: box.height };
}

/// Where a tooltip for `element` stays (`tooltipPosition`'s `bounds`): its nearest ancestor that
/// scrolls (the window for an element in a popup, whose tooltip may leave the popup, or outside any
/// scroller), cut to the window and below a `data-tooltip-covered` band across its top that the
/// element is not in, and below an open Find bar (ui/popupInset.ts), the top layer of its pane: a
/// timestamp's tooltip under it flips below its row (Leo 2026-11-07: "we don't want it to be
/// coverable by other sorts of things. Like, for example, these hover previews").
function boundsOf(element: Element, view: { width: number; height: number }): Box | undefined {
  const doc = element.ownerDocument;
  const win = doc.defaultView;
  if (!win) return undefined;
  let area = { left: 0, top: 0, right: view.width, bottom: view.height };
  if (!element.closest(".ui-popup"))
    for (let node = element.parentElement; node && node !== doc.body && node !== doc.documentElement;) {
      const overflow = win.getComputedStyle(node).overflowY;
      if (overflow === "auto" || overflow === "scroll") {
        const box = node.getBoundingClientRect();
        area = {
          left: Math.max(0, box.left),
          top: Math.max(0, box.top),
          right: Math.min(view.width, box.right),
          bottom: Math.min(view.height, box.bottom),
        };
        break;
      }
      node = node.parentElement;
    }
  for (const cover of doc.querySelectorAll("[data-tooltip-covered]")) {
    if (cover.contains(element)) continue;
    const box = cover.getBoundingClientRect();
    if (box.top <= area.top + 1 && box.bottom > area.top && box.left < area.right && box.right > area.left)
      area.top = box.bottom;
  }
  // The bar's own controls keep their tooltips' usual place.
  const findBar = popupInsetOf("findBar");
  if (findBar > area.top && !element.closest(".acpmux-find")) area.top = Math.min(findBar, area.bottom);
  const width = area.right - area.left;
  const height = area.bottom - area.top;
  return width > 0 && height > 0 ? { left: area.left, top: area.top, width, height } : undefined;
}

/// The element a tooltip for `element` is placed at: its `data-tooltip-anchor` part when it has
/// one with a box (a pane-wide row's words, MessageGroupHead.tsx), else the element itself.
function anchorOf(element: Element): Element {
  const selector = element.getAttribute("data-tooltip-anchor");
  if (!selector) return element;
  let part: Element | null = null;
  try {
    part = element.querySelector(selector);
  } catch {
    return element;
  }
  const box = part?.getBoundingClientRect();
  return part && box && (box.width > 0 || box.height > 0) ? part : element;
}

/// The box a tooltip for `element` is placed at: its named part's (`anchorOf`), else what the
/// element draws (`drawnBox`).
function anchorBox(element: Element): Box {
  const part = anchorOf(element);
  const box = part.getBoundingClientRect();
  return part === element ? drawnBox(element, box) : box;
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
    const anchor = anchorBox(target);
    const scale = tooltipScale(doc);
    const fadeIn = !instant && (tip.hidden === true || ending !== undefined);
    endFade();
    tip.toggleAttribute("data-instant", !fadeIn);
    tip.toggleAttribute("data-starting-style", fadeIn);
    tip.hidden = false;
    // Measured from the window's left: a fixed box still at the last tooltip's place gets only the
    // room right of it, and its text would wrap inside a word ("Chat summar / y").
    tip.style.left = "0px";
    tip.style.top = "0px";
    const width = tooltipWidth({
      width: anchor.width,
      truncated: false,
      view: doc.documentElement.clientWidth,
      scale,
    });
    tip.style.minWidth = `${width.min}px`;
    tip.style.maxWidth = `${width.max}px`;
    const requestedSide = target.getAttribute("data-tooltip-side");
    const side = requestedSide === "left" || requestedSide === "bottom" ? requestedSide : "top";
    // A rail's hint sits outside the popup rim, centered on its hovered tab.
    const surface = side === "left" ? target.closest(".ui-popup")?.getBoundingClientRect() : undefined;
    const view = { width: doc.documentElement.clientWidth, height: doc.documentElement.clientHeight };
    const position = tooltipPosition(
      {
        left: surface?.left ?? anchor.left,
        top: anchor.top,
        width: surface?.width ?? anchor.width,
        height: anchor.height,
      },
      tip.getBoundingClientRect(),
      view,
      side,
      scale,
      boundsOf(target, view),
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
  // An element that came under a still pointer (the page laid out again): it waits for the pointer to move.
  const motion = new PointerMotion();
  let still: Element | undefined;
  const onOver = (event: PointerEvent) => {
    if (event.pointerType && event.pointerType !== "mouse") return;
    const element = (event.target as Element | null)?.closest?.("[title], [data-tooltip]") ?? undefined;
    if (element && element !== target && !motion.arrived(event)) {
      still = element;
      return;
    }
    over(element);
  };
  const over = (element: Element | undefined) => {
    still = undefined;
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
  const onMove = (event: PointerEvent) => {
    if (!motion.moved(event) || !still) return;
    const element = still;
    still = undefined;
    if (element.isConnected && element.contains(event.target as Node | null)) over(element);
  };
  const onOut = (event: PointerEvent) => {
    // Leaving the element (not moving onto one of its children) hides it.
    const into = event.relatedTarget as Node | null;
    if (still && !still.contains(into)) still = undefined;
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
  doc.addEventListener("pointermove", onMove, true);
  doc.addEventListener("pointerout", onOut);
  doc.addEventListener("pointerdown", dismiss, true);
  doc.addEventListener("keydown", dismiss, true);
  doc.addEventListener("scroll", onScroll, true);
  win.addEventListener("blur", dismiss);
  // Find's bar opening (or anything new covering the page's top) takes away a tooltip under it.
  const unwatchInset = onPopupInsetChange(dismiss);
  return () => {
    unwatchInset();
    dismiss();
    intent.dispose();
    doc.removeEventListener("pointerover", onOver);
    doc.removeEventListener("pointermove", onMove, true);
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
