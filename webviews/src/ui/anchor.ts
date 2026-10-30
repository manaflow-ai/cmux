import { useLayoutEffect, useRef, useState, type CSSProperties, type RefObject } from "react";

/** The gap used by every anchored menu and popover. Keep this in one place. */
export const UI_ANCHOR_GAP = 6;

export type UiAnchorSide = "above" | "below";
export type UiAnchorAlign = "start" | "end";

export interface UiAnchorBox {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface UiOverlaySize {
  width: number;
  height: number;
}

export interface UiViewport {
  width: number;
  height: number;
}

export interface UiOverlayPosition {
  left: number;
  top: number;
  side: UiAnchorSide;
  maxHeight: number;
}

export interface UiAnchorOptions {
  side?: UiAnchorSide;
  align?: UiAnchorAlign;
  gap?: number;
  margin?: number;
  direction?: "ltr" | "rtl";
  /** The shortest the overlay will be once its content is in (the model picker's floor). The side
   * is chosen for this height, not only the measured one, so an overlay that opens before its
   * content (and measures short) still opens on the side it will fit. When neither side has it,
   * the overlay opens below and runs past the visible box, where its scroller can scroll to it
   * (above, it would run off the top, out of reach). */
  minHeight?: number;
  /** A selector for the box the overlay stays inside, found from the anchor (the agent pane's chat
   * column), cut with the visible box; the overlay learns its width as `--available-width`. */
  boundary?: string;
}

// An overlay is mounted before its measured coordinates are available. Keep that first hidden
// frame out of document flow; otherwise a menu without its own absolute-positioning class (the
// model picker) briefly pushes the composer before the layout effect can place it.
const HIDDEN_ANCHOR_STYLE: CSSProperties = {
  position: "absolute",
  left: 0,
  top: 0,
  right: "auto",
  bottom: "auto",
  visibility: "hidden",
};

/**
 * The side an overlay opens on, the one rule every anchored overlay uses: the requested side when
 * the overlay fits there or that side has at least the other's room, else the other side. A
 * portaled popover takes it once, when it opens (`useOpenSide`), so it never flips while open.
 */
export function resolveUiSide(
  anchor: Pick<UiAnchorBox, "top" | "bottom">,
  height: number,
  viewportHeight: number,
  options: Pick<UiAnchorOptions, "side" | "gap" | "margin"> = {},
): UiAnchorSide {
  const gap = options.gap ?? UI_ANCHOR_GAP;
  const margin = options.margin ?? 8;
  const below = Math.max(0, viewportHeight - anchor.bottom - gap - margin);
  const above = Math.max(0, anchor.top - gap - margin);
  return (options.side ?? "below") === "below"
    ? below >= height || below >= above
      ? "below"
      : "above"
    : above >= height || above >= below
      ? "above"
      : "below";
}

/**
 * Resolve an overlay in viewport coordinates. Both inputs are DOM rects, so a
 * page zoom or a device scale factor cannot introduce a second coordinate
 * space. The requested side is preferred, then flipped when the other side
 * has more room. The leading edge stays attached while the overlay is clamped
 * to the viewport.
 */
export function resolveUiOverlayPosition(
  anchor: UiAnchorBox,
  overlay: UiOverlaySize,
  viewport: UiViewport,
  options: UiAnchorOptions = {},
): UiOverlayPosition {
  const side = options.side ?? "below";
  const align = options.align ?? "start";
  const gap = options.gap ?? UI_ANCHOR_GAP;
  const margin = options.margin ?? 8;
  const direction = options.direction ?? "ltr";
  const spaceBelow = Math.max(0, viewport.height - anchor.bottom - gap - margin);
  const spaceAbove = Math.max(0, anchor.top - gap - margin);
  const floor = options.minHeight ?? 0;
  const resolvedSide =
    floor > 0 && spaceAbove < floor && spaceBelow < floor
      ? "below"
      : resolveUiSide(anchor, Math.max(overlay.height, floor), viewport.height, { side, gap, margin });
  const available = resolvedSide === "below" ? spaceBelow : spaceAbove;
  const idealLeft =
    align === "start"
      ? direction === "rtl"
        ? anchor.right - overlay.width
        : anchor.left
      : direction === "rtl"
        ? anchor.left
        : anchor.right - overlay.width;
  const maxLeft = Math.max(margin, viewport.width - overlay.width - margin);
  const left = Math.min(Math.max(idealLeft, margin), maxLeft);
  const top = resolvedSide === "below" ? anchor.bottom + gap : anchor.top - gap - overlay.height;
  return { left, top, side: resolvedSide, maxHeight: Math.max(0, available) };
}

/**
 * The part of the window a local overlay can show in: the window, cut by every ancestor from its
 * offset parent up that clips overflow (a scroller), as those are the boxes that clip an
 * absolutely positioned overlay. A menu inside the New Tab scroller is sized to what the scroller
 * shows, not to the window (cx-m6jn0).
 */
function visibleBox(overlay: HTMLElement): UiAnchorBox {
  const view = overlay.ownerDocument.defaultView ?? window;
  let box: UiAnchorBox = { left: 0, top: 0, right: view.innerWidth, bottom: view.innerHeight };
  for (let node = overlay.offsetParent; node instanceof HTMLElement; node = node.parentElement) {
    const style = view.getComputedStyle(node);
    if (style.overflowX === "visible" && style.overflowY === "visible") continue;
    const rect = node.getBoundingClientRect();
    box = {
      left: Math.max(box.left, rect.left),
      top: Math.max(box.top, rect.top),
      right: Math.min(box.right, rect.right),
      bottom: Math.min(box.bottom, rect.bottom),
    };
  }
  return box;
}

function scaleFor(container: HTMLElement | null): { x: number; y: number } {
  if (!container || container.offsetWidth === 0 || container.offsetHeight === 0) return { x: 1, y: 1 };
  const rect = container.getBoundingClientRect();
  return {
    x: rect.width / container.offsetWidth || 1,
    y: rect.height / container.offsetHeight || 1,
  };
}

/** Computed max-height can still be a min()/calc() expression. Let layout resolve its units. */
function cssMaxHeight(node: HTMLElement): number {
  const value = (node.ownerDocument.defaultView ?? window).getComputedStyle(node).maxHeight;
  if (!value || value === "none") return Number.POSITIVE_INFINITY;
  if (/^[\d.]+px$/.test(value)) return Number.parseFloat(value);
  const parent = node.parentElement;
  if (!parent) return Number.POSITIVE_INFINITY;
  const probe = node.ownerDocument.createElement("div");
  Object.assign(probe.style, {
    position: "absolute",
    visibility: "hidden",
    pointerEvents: "none",
    width: "0",
    height: value,
    padding: "0",
    border: "0",
  });
  if (!probe.style.height) return Number.POSITIVE_INFINITY;
  parent.appendChild(probe);
  const scale = scaleFor(probe.offsetParent instanceof HTMLElement ? probe.offsetParent : null);
  const height = probe.getBoundingClientRect().height / scale.y;
  probe.remove();
  return height;
}

/**
 * Position a local (non-portal) overlay against its trigger. The conversion
 * through the offset parent accounts for transformed/zoomed webview roots and
 * keeps the overlay in the same coordinate space as the trigger.
 */
export function useUiAnchor(
  anchor: RefObject<HTMLElement | null>,
  overlay: RefObject<HTMLElement | null>,
  open: boolean,
  options: UiAnchorOptions = {},
): CSSProperties {
  const { align, boundary, direction: requestedDirection, gap, margin, minHeight, side } = options;
  const [style, setStyle] = useState<CSSProperties>(HIDDEN_ANCHOR_STYLE);
  const heightOwner = useRef<{ node: HTMLElement; caller: boolean } | null>(null);
  useLayoutEffect(() => {
    if (!open) {
      setStyle(HIDDEN_ANCHOR_STYLE);
      return;
    }
    const update = () => {
      const anchorNode = anchor.current;
      const overlayNode = overlay.current;
      if (!anchorNode || !overlayNode) return;
      // A caller such as ModelPicker owns its numeric height bounds. Ordinary menus use their
      // stylesheet cap; remove our prior inline bound before reading it again on resize.
      if (heightOwner.current?.node !== overlayNode)
        heightOwner.current = { node: overlayNode, caller: overlayNode.style.maxHeight !== "" };
      const callerHeight = heightOwner.current.caller;
      if (!callerHeight) {
        overlayNode.style.visibility = "hidden";
        overlayNode.style.maxHeight = "";
      }
      const cssCap = callerHeight ? Number.POSITIVE_INFINITY : cssMaxHeight(overlayNode);
      const a = anchorNode.getBoundingClientRect();
      const o = overlayNode.getBoundingClientRect();
      const direction =
        requestedDirection ??
        (anchorNode.ownerDocument.defaultView?.getComputedStyle(anchorNode).direction === "rtl" ? "rtl" : "ltr");
      // Resolved in the visible box's coordinates, then back in the window's.
      let box = visibleBox(overlayNode);
      const bound = boundary ? anchorNode.closest(boundary)?.getBoundingClientRect() : undefined;
      if (bound)
        box = {
          left: Math.max(box.left, bound.left),
          top: Math.max(box.top, bound.top),
          right: Math.min(box.right, bound.right),
          bottom: Math.min(box.bottom, bound.bottom),
        };
      const inBox = resolveUiOverlayPosition(
        { left: a.left - box.left, top: a.top - box.top, right: a.right - box.left, bottom: a.bottom - box.top },
        { width: o.width, height: o.height },
        { width: box.right - box.left, height: box.bottom - box.top },
        { align, direction, gap, margin, minHeight, side },
      );
      const parent = overlayNode.offsetParent instanceof HTMLElement ? overlayNode.offsetParent : null;
      const parentRect = parent?.getBoundingClientRect() ?? { left: 0, top: 0 };
      const scale = scaleFor(parent);
      const maxHeight = Math.min(inBox.maxHeight / scale.y, cssCap);
      // Constraining the height can change an above-menu's top. Measure that final box before
      // revealing it, rather than asking ResizeObserver to correct the next visible frame.
      if (!callerHeight) overlayNode.style.maxHeight = `${maxHeight}px`;
      const sized = callerHeight ? o : overlayNode.getBoundingClientRect();
      const placed = resolveUiOverlayPosition(
        { left: a.left - box.left, top: a.top - box.top, right: a.right - box.left, bottom: a.bottom - box.top },
        { width: sized.width, height: sized.height },
        { width: box.right - box.left, height: box.bottom - box.top },
        { align, direction, gap, margin, minHeight, side: inBox.side },
      );
      const position = { ...placed, left: placed.left + box.left, top: placed.top + box.top };
      const left = (position.left - parentRect.left) / scale.x + (parent?.scrollLeft ?? 0);
      const top = (position.top - parentRect.top) / scale.y + (parent?.scrollTop ?? 0);
      // With a boundary, the width the overlay may take: the box less its margin on both sides.
      const room = Math.max(0, box.right - box.left - 2 * (margin ?? 8)) / scale.x;
      const nextStyle = {
        position: "absolute",
        left,
        top,
        right: "auto",
        bottom: "auto",
        maxHeight,
        visibility: "visible",
        ...(bound ? { "--available-width": `${room}px` } : {}),
      } as CSSProperties;
      if (!callerHeight) {
        Object.assign(overlayNode.style, {
          left: `${left}px`,
          top: `${top}px`,
          maxHeight: `${maxHeight}px`,
          visibility: "visible",
        });
      }
      setStyle(nextStyle);
    };
    update();
    window.addEventListener("resize", update);
    window.addEventListener("scroll", update, true);
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(update);
    observer?.observe(anchor.current!);
    observer?.observe(overlay.current!);
    return () => {
      window.removeEventListener("resize", update);
      window.removeEventListener("scroll", update, true);
      observer?.disconnect();
    };
  }, [align, anchor, boundary, gap, margin, minHeight, open, overlay, requestedDirection, side]);
  return style;
}
