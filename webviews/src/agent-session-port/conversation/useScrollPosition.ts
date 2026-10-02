// Applies a captured scroll position to a real scroll container, without effects.
import { useCallback, useRef, type RefCallback } from "react";

/**
 * Scroll offset in px from the top, `"bottom"` to stay pinned to the end, or an anchor: the
 * element rendered with `data-anchor={anchor}` (a turn's "Worked for" row, a group header, a
 * row; keys from derive.ts) sits `at` px below the scroller's top edge.
 */
export type ScrollPosition = number | "bottom" | { anchor: string; at: number };

/**
 * Contract: attach `ref` to the scroll container and spread `handlers` on it. When the
 * container mounts, its scrollTop is set to `position`; while the content's size settles
 * (async code renderers paint after mount) a ResizeObserver, owned by the ref and torn down
 * by its cleanup, re-applies it. The first user scroll gesture releases the position, so
 * the transcript then scrolls like any scroller.
 */
export function useScrollPosition(position: ScrollPosition) {
  const released = useRef(false);
  const ref = useCallback<RefCallback<HTMLElement>>(
    (el) => {
      if (!el) return;
      released.current = false;
      const apply = () => {
        if (released.current) return;
        el.scrollTop = resolveScroll(position, el);
      };
      apply();
      const ro = new ResizeObserver(apply);
      for (const child of Array.from(el.children)) ro.observe(child);
      return () => ro.disconnect();
    },
    [position],
  );
  const release = useCallback(() => {
    released.current = true;
  }, []);
  return {
    ref,
    handlers: {
      onWheel: release,
      onTouchStart: release,
      onKeyDown: release,
      onPointerDown: release,
    },
  };
}

/** The scrollTop that puts `position` in place inside the scroller `el`. */
export function resolveScroll(position: ScrollPosition, el: HTMLElement): number {
  if (position === "bottom") return el.scrollHeight;
  if (typeof position === "number") return position;
  const target = el.querySelector<HTMLElement>(`[data-anchor="${CSS.escape(position.anchor)}"]`);
  if (!target) return 0;
  const offset = target.getBoundingClientRect().top - el.getBoundingClientRect().top + el.scrollTop;
  return offset - position.at;
}
