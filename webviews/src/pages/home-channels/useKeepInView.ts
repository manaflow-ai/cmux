// Keeps the keyboard's current row in view: when `key` changes, the row with that `data-key`
// scrolls to the nearest edge (no jump when it is already visible). One narrow layout effect on
// the key alone; the timeline's virtual window renders rows near the viewport, so the next row
// of j/k is always in the DOM.
import { useLayoutEffect, type RefObject } from "react";

export function useKeepInView(scroller: RefObject<HTMLElement | null>, key: string | undefined): void {
  useLayoutEffect(() => {
    if (!key) return;
    const row = scroller.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(key)}"]`);
    row?.scrollIntoView({ block: "nearest" });
  }, [scroller, key]);
}
