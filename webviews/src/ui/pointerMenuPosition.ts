import { useLayoutEffect, useState, type RefObject } from "react";
import { useUiDirection } from "./UiProvider";
import { resolvePointerMenuPosition, scaleFor } from "./anchor";

export function pointerAnchor(x: number, y: number, width = 0) {
  return {
    getBoundingClientRect: () => ({
      x,
      y,
      width,
      height: 0,
      left: x,
      top: y,
      right: x + width,
      bottom: y,
      toJSON: () => ({}),
    }),
  };
}

type Anchor = { getBoundingClientRect(): { left: number; top: number } };

/** Reposition the open menu when its rows or viewport change size. Base UI takes the same
 * measured edge as a virtual anchor, so it can still translate into its portal's coordinates. */
export function usePointerMenuPosition(
  popup: HTMLElement | null,
  source: Anchor | RefObject<Anchor | null> | null,
  container: HTMLElement | null = null,
) {
  const uiDirection = useUiDirection();
  const [place, setPlace] = useState<{
    left: number;
    top: number;
    side: "top" | "bottom";
    anchor: ReturnType<typeof pointerAnchor>;
  } | null>(null);
  useLayoutEffect(() => {
    const anchor = source && "current" in source ? source.current : source;
    if (!popup || !anchor) {
      setPlace(null);
      return;
    }
    const view = popup.ownerDocument.defaultView ?? window;
    const update = () => {
      const { left: x, top: y } = anchor.getBoundingClientRect();
      const size = popup.getBoundingClientRect();
      const direction = view.getComputedStyle(popup).direction === "rtl" ? "rtl" : uiDirection;
      const { left, top, side } = resolvePointerMenuPosition(
        { x, y },
        size,
        { width: view.innerWidth, height: view.innerHeight },
        undefined,
        direction,
      );
      // Base UI translates its virtual anchor. The standalone portal places its menu in a fixed
      // backdrop: its CSS offsets are local lengths, even when the document has CSS zoom.
      const bounds = container?.getBoundingClientRect();
      const scale = scaleFor(container, bounds);
      const above = side === "above";
      setPlace({
        left: (left - (bounds?.left ?? 0)) / scale.x,
        top: (top - (bounds?.top ?? 0)) / scale.y,
        side: above ? "top" : "bottom",
        anchor: pointerAnchor(left, above ? top + size.height : top, size.width),
      });
    };
    update();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);
    observer?.observe(popup);
    if (container) observer?.observe(container);
    view.addEventListener("resize", update);
    return () => {
      observer?.disconnect();
      view.removeEventListener("resize", update);
    };
  }, [container, popup, source, uiDirection]);
  return place;
}
