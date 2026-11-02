import { createContext, use, useLayoutEffect, useMemo, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";

/**
 * The element a menu draws in to leave every backdrop root around `from` (Filter Effects 2: an
 * ancestor with a backdrop-filter, filter, mask, clip-path, opacity under 1 or a blend mode). Inside
 * one, a popup's own backdrop-filter sees only that root's content: the composer's glass box is one,
 * so the + menu's glass showed the project and machine pills behind the composer through it sharp
 * (Leo, 2026-10-31: "our + button is ass"). The parent of the outermost root inside the pane's shell
 * (`.acpmux-shell`, which carries the menu's colour tokens; the body on a page without one), or null
 * when there is none (the menu then stays beside its button).
 */
export function backdropLayer(from: Element | null): HTMLElement | null {
  const view = from?.ownerDocument.defaultView;
  if (!from || !view) return null;
  const shell = from.closest(".acpmux-shell") ?? from.ownerDocument.body;
  let outermost: Element | null = null;
  for (let node = from.parentElement; node && node !== shell; node = node.parentElement)
    if (isBackdropRoot(view.getComputedStyle(node))) outermost = node;
  return outermost?.parentElement ?? null;
}

/** Whether an element with this style is a backdrop root (Filter Effects 2). */
export function isBackdropRoot(style: CSSStyleDeclaration): boolean {
  const set = (value: string | undefined) => !!value && value !== "none";
  const backdrop = style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter");
  const mask = style.maskImage || style.getPropertyValue("-webkit-mask-image");
  const opacity = Number.parseFloat(style.opacity);
  return (
    set(backdrop) ||
    set(style.filter) ||
    set(mask) ||
    set(style.clipPath) ||
    (Number.isFinite(opacity) && opacity < 1) ||
    (!!style.mixBlendMode && style.mixBlendMode !== "normal")
  );
}

// The composer's `/` and `@` lists (SlashMenu, MentionMenu) float above its box, over the
// transcript. The box is glass (`.ui-glass`) and so a backdrop root: a list drawn inside it frosted
// the box alone, and the transcript read sharp through it, where the mode and model menus (portaled
// out) frost it. So a list draws out of the box, in a layer outside every backdrop root around it
// (backdropLayer, as the + menu does), kept on the box's place and size: the list's own CSS
// (styles.css `.acpmux-slash-menu`: 6 px above, the box's edges, its height cap) places it as
// before. The layer stays in the composer, so its colour tokens and rules still reach the rows.
// Not the page's portal container (UiProvider): that sits outside `.acpmux-shell` and its tokens.

const ListAnchor = createContext<{ box: HTMLElement | null; inert: boolean }>({ box: null, inert: false });

/** The box the composer's lists float above (the chat's `.acpmux-composer-box`, New Tab's `.nt-box`). */
export function ComposerListAnchor({
  box,
  inert = false,
  children,
}: {
  box: HTMLElement | null;
  /// The box takes no input (a locked composer, a cloud start): nor do its lists.
  inert?: boolean;
  children: ReactNode;
}) {
  const value = useMemo(() => ({ box, inert }), [box, inert]);
  return <ListAnchor value={value}>{children}</ListAnchor>;
}

/** The box the lists float above, or null outside a composer (a gallery card, a unit test). */
export function useComposerListBox(): HTMLElement | null {
  return use(ListAnchor).box;
}

/**
 * Draws a composer list in its layer over the box. Outside a composer (no anchor) it draws in place.
 * Layout is read as the list opens and again only when the box, a box between it and the layer's
 * host, or the layer's parent changes size (the draft grows, a notice shows over the box, the pane
 * resizes) or a scroller between them moves the box: no frame loop.
 */
export function ComposerListLayer({ children }: { children: ReactNode }) {
  const { box, inert } = use(ListAnchor);
  const layer = useRef<HTMLDivElement>(null);
  // Found as the list opens (it mounts open): out of the box's glass, or beside the box when no
  // backdrop root is around it.
  const host = useMemo(() => (box ? (backdropLayer(box) ?? box.parentElement) : null), [box]);
  useLayoutEffect(() => {
    const node = layer.current;
    if (!box || !node) return;
    const parent = node.offsetParent instanceof HTMLElement ? node.offsetParent : null;
    const place = () => {
      const at = box.getBoundingClientRect();
      const origin = parent?.getBoundingClientRect() ?? { left: 0, top: 0, width: 0, height: 0 };
      // A zoomed page (the pane's text size) scales the parent's box: its CSS pixels are what we write.
      const scaleX = parent && parent.offsetWidth ? origin.width / parent.offsetWidth || 1 : 1;
      const scaleY = parent && parent.offsetHeight ? origin.height / parent.offsetHeight || 1 : 1;
      const left = (at.left - origin.left) / scaleX - (parent?.clientLeft ?? 0) + (parent?.scrollLeft ?? 0);
      const top = (at.top - origin.top) / scaleY - (parent?.clientTop ?? 0) + (parent?.scrollTop ?? 0);
      Object.assign(node.style, {
        left: `${left}px`,
        top: `${top}px`,
        // The rect's own fractions, not offsetHeight's rounding: the list's bottom stays 6 px off the box.
        width: `${at.width / scaleX}px`,
        height: `${at.height / scaleY}px`,
      });
    };
    place();
    // A scroller around the box but not the layer moves one without the other; the transcript's
    // scroll and the list's own rows move neither.
    const onScroll = (event: Event) => {
      const scroller = event.target;
      if (scroller instanceof Node && scroller.contains(box) && !scroller.contains(node)) place();
    };
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(place);
    observer?.observe(box);
    if (parent) observer?.observe(parent);
    // A notice over the box (New Tab's sign-in note, a start error, cloud status) moves it down and
    // resizes neither it nor the layer's parent: it grows a box between them (`.nt-composer`). So
    // each one from the box up to the layer's host is watched too, a short fixed chain.
    for (let node = box.parentElement; node && node !== parent; node = node.parentElement) {
      observer?.observe(node);
      if (node === host) break;
    }
    window.addEventListener("resize", place);
    window.addEventListener("scroll", onScroll, true);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", onScroll, true);
    };
  }, [box, host]);
  if (!box || !host) return <>{children}</>;
  return createPortal(
    <div ref={layer} className="acpmux-composer-list-layer" inert={inert}>
      {children}
    </div>,
    host,
  );
}
