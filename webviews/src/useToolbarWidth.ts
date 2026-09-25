import { useEffect, useRef, useState } from "react";

/**
 * Tracks the content-box width of the element behind `ref` with a single
 * ResizeObserver. This is the one legitimate effect in the toolbar: it owns the
 * observer's full lifecycle (create on mount / element change, disconnect on
 * cleanup) and exposes only a derived number, so the rest of the toolbar stays
 * declarative. Returns `null` until the first measurement, so callers can render
 * the full bar (CSS still guarantees no overlap) before width is known.
 */
export function useToolbarWidth(ref: React.RefObject<HTMLElement | null>): number | null {
  const [width, setWidth] = useState<number | null>(null);
  const widthRef = useRef<number | null>(null);
  useEffect(() => {
    const element = ref.current;
    if (!element || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const next = entry.contentBoxSize?.[0]?.inlineSize ?? entry.contentRect.width;
        // Round to whole px and dedupe so sub-pixel jitter does not re-render.
        const rounded = Math.round(next);
        if (rounded !== widthRef.current) {
          widthRef.current = rounded;
          setWidth(rounded);
        }
      }
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
  return width;
}
