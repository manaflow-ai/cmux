// macOS-style overlay scrollbar thumbs. Codex shows them in the capture; Chromium in
// headless/compare mode hides native scrollbars, so the pane hides native bars everywhere
// (scrollbar-width: none) and draws these from the scroller's live metrics instead.
import { useCallback, useRef, useState } from "react";

export interface ThumbGeometry {
  offset: number;
  length: number;
}

/**
 * Tracks one scroll element and returns the thumb geometry along `axis`.
 * `insetStart`/`insetEnd` shrink the track at both ends (CSS px).
 */
export function useOverlayThumb(axis: "x" | "y", insetStart: number, insetEnd: number) {
  const [thumb, setThumb] = useState<ThumbGeometry | null>(null);
  const target = useRef<HTMLElement | null>(null);

  const measure = useCallback(() => {
    const el = target.current;
    if (!el) return;
    const size = axis === "x" ? el.clientWidth : el.clientHeight;
    const total = axis === "x" ? el.scrollWidth : el.scrollHeight;
    const pos = axis === "x" ? el.scrollLeft : el.scrollTop;
    if (total <= size + 1) {
      setThumb(null);
      return;
    }
    const track = size - insetStart - insetEnd;
    const length = Math.max(18, (track * size) / total);
    const offset = insetStart + ((track - length) * pos) / (total - size);
    setThumb((prev) =>
      prev && prev.offset === offset && prev.length === length ? prev : { offset, length },
    );
  }, [axis, insetStart, insetEnd]);

  const attach = useCallback(
    (el: HTMLElement | null) => {
      if (target.current === el) {
        measure();
        return;
      }
      target.current?.removeEventListener("scroll", measure);
      target.current = el;
      el?.addEventListener("scroll", measure, { passive: true });
      measure();
    },
    [measure],
  );

  return { thumb, attach, measure };
}
