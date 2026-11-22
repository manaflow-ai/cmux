// The server page's host: the menu bar item's popover (ServerPanelPopover.swift), one route at a time
// (`#/server-panel`). The page measures its route and the popover takes that size in the same frame.
import { useLayoutEffect, useRef, type RefObject } from "react";
import type { PageClient } from "../shared/pageClient";

export const CardOps = {
  /** `{card, height, width}` (CSS px) → null: the route's measured size. */
  resize: "cmux.card.resize",
} as const;

/** The route a hash names (`#/server-panel` → `server-panel`), or null. */
export function cardOfHash(hash: string): string | null {
  const match = /^#\/([a-z0-9-]+)/.exec(hash);
  return match ? match[1]! : null;
}

/** Reports `ref`'s size to the popover whenever it changes (the first layout included). */
export function useCardSize(client: PageClient | null, card: string, ref: RefObject<HTMLElement | null>): void {
  const last = useRef("");
  const report = () => {
    const element = ref.current;
    if (!client || !element) return;
    const width = Math.ceil(element.offsetWidth);
    const height = Math.ceil(element.offsetHeight);
    const key = JSON.stringify([width, height]);
    if (key === last.current || height === 0) return;
    last.current = key;
    void client.call(CardOps.resize, { card, width, height }).catch(() => {});
  };
  const latest = useRef(report);
  latest.current = report;
  // A step change may resize the card before the observer runs.
  useLayoutEffect(() => latest.current());
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => latest.current());
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
}
