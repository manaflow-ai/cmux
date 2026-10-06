import { useLayoutEffect, useState, type CSSProperties, type RefObject } from "react";

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
  const resolvedSide = side === "below"
    ? spaceBelow >= overlay.height || spaceBelow >= spaceAbove
      ? "below"
      : "above"
    : spaceAbove >= overlay.height || spaceAbove >= spaceBelow
      ? "above"
      : "below";
  const available = resolvedSide === "below" ? spaceBelow : spaceAbove;
  const idealLeft = align === "start"
    ? direction === "rtl" ? anchor.right - overlay.width : anchor.left
    : direction === "rtl" ? anchor.left : anchor.right - overlay.width;
  const maxLeft = Math.max(margin, viewport.width - overlay.width - margin);
  const left = Math.min(Math.max(idealLeft, margin), maxLeft);
  const top = resolvedSide === "below" ? anchor.bottom + gap : anchor.top - gap - overlay.height;
  return { left, top, side: resolvedSide, maxHeight: Math.max(0, available) };
}

function scaleFor(container: HTMLElement | null): { x: number; y: number } {
  if (!container || container.offsetWidth === 0 || container.offsetHeight === 0) return { x: 1, y: 1 };
  const rect = container.getBoundingClientRect();
  return {
    x: rect.width / container.offsetWidth || 1,
    y: rect.height / container.offsetHeight || 1,
  };
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
  const [style, setStyle] = useState<CSSProperties>({ visibility: "hidden" });
  useLayoutEffect(() => {
    if (!open) {
      setStyle({ visibility: "hidden" });
      return;
    }
    const update = () => {
      const anchorNode = anchor.current;
      const overlayNode = overlay.current;
      if (!anchorNode || !overlayNode) return;
      const a = anchorNode.getBoundingClientRect();
      const o = overlayNode.getBoundingClientRect();
      const direction = options.direction ?? (getComputedStyle(anchorNode).direction === "rtl" ? "rtl" : "ltr");
      const position = resolveUiOverlayPosition(
        { left: a.left, top: a.top, right: a.right, bottom: a.bottom },
        { width: o.width, height: o.height },
        { width: window.innerWidth, height: window.innerHeight },
        { ...options, direction },
      );
      const parent = overlayNode.offsetParent instanceof HTMLElement ? overlayNode.offsetParent : null;
      const parentRect = parent?.getBoundingClientRect() ?? { left: 0, top: 0 };
      const scale = scaleFor(parent);
      const left = (position.left - parentRect.left) / scale.x + (parent?.scrollLeft ?? 0);
      const top = (position.top - parentRect.top) / scale.y + (parent?.scrollTop ?? 0);
      setStyle({
        position: "absolute",
        left,
        top,
        right: "auto",
        bottom: "auto",
        maxHeight: position.maxHeight / scale.y,
        visibility: "visible",
      });
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
  }, [anchor, overlay, open, options.align, options.direction, options.gap, options.margin, options.side]);
  return style;
}
