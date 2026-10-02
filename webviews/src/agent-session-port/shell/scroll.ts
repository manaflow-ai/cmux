// Real scroll containers with macOS-style overlay thumbs, without effects.
import { useCallback, useRef, useState, type RefCallback } from "react";

export type ThumbGeometry = { top: number; height: number };

export type ScrollAreaOptions = {
  /** Track inset at the top and bottom of the scroller, CSS px. */
  insetStart?: number;
  insetEnd?: number;
  /** Shortest thumb, CSS px. */
  minThumb?: number;
  /** Reports user scrolling (e.g. to keep the position in app state). Keep it stable. */
  onScroll?: (top: number) => void;
};

/**
 * Contract: attach `ref` to an `overflow: auto` element and spread `handlers` on it. On
 * mount the ref applies `position` (scrollTop, CSS px, or a function of the scroller that
 * returns it; keep that function stable) and re-applies it while the content
 * settles (a ResizeObserver owned by the ref, torn down by its cleanup) until the first user
 * gesture. `residual` is the sub-pixel part Chromium dropped (translate the content by
 * -residual). `thumb` is the overlay thumb derived from the live scroll metrics, in the
 * scroller's own coordinates (null when the content fits).
 */
export function useScrollArea(
  position: number | ((el: HTMLElement) => number) = 0,
  { insetStart = 0, insetEnd = 0, minThumb = 18, onScroll }: ScrollAreaOptions = {},
) {
  const [thumb, setThumb] = useState<ThumbGeometry | null>(null);
  // Chromium snaps scrollTop to whole CSS px; a captured half-pixel offset is drawn as this
  // residual translate of the content until the user scrolls.
  const [residual, setResidual] = useState(0);
  const released = useRef(false);

  const ref = useCallback<RefCallback<HTMLElement>>(
    (el) => {
      if (!el) return;
      released.current = false;
      const measure = () => {
        const size = el.clientHeight;
        const total = el.scrollHeight;
        if (total <= size + 1) return setThumb(null);
        const track = size - insetStart - insetEnd;
        const height = Math.max(minThumb, (track * size) / total);
        const top = insetStart + ((track - height) * el.scrollTop) / (total - size);
        setThumb((prev) =>
          prev && prev.top === top && prev.height === height ? prev : { top, height },
        );
      };
      const apply = () => {
        if (!released.current) {
          // A resolver measures the target offset in the laid-out content (e.g. an anchor).
          const target = typeof position === "function" ? position(el) : position;
          el.scrollTop = target;
          const rest = target - el.scrollTop;
          setResidual(Math.abs(rest) < 1 ? rest : 0);
        }
        measure();
      };
      const scrolled = () => {
        measure();
        if (released.current) onScroll?.(el.scrollTop);
      };
      apply();
      const ro = new ResizeObserver(apply);
      for (const child of Array.from(el.children)) ro.observe(child);
      el.addEventListener("scroll", scrolled, { passive: true });
      return () => {
        ro.disconnect();
        el.removeEventListener("scroll", scrolled);
      };
    },
    // onScroll should be stable (e.g. built from a reducer's dispatch).
    [position, insetStart, insetEnd, minThumb, onScroll],
  );
  const release = useCallback(() => {
    released.current = true;
    setResidual(0);
  }, []);
  return {
    ref,
    thumb,
    residual,
    handlers: {
      onWheel: release,
      onTouchStart: release,
      onKeyDown: release,
      onPointerDown: release,
    },
  };
}
