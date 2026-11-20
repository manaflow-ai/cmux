import { use, useLayoutEffect, useMemo, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { backdropLayer, ListAnchor } from "./backdropLayerModel";
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
