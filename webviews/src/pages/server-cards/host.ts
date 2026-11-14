// The server card page's host: one floating glass panel (WebCardPanel.swift) that shows one card
// per route (`#/pair-invite`). The page measures its card and the panel takes that size in the same
// frame, growing downward from its top edge; the card's Cancel or Done closes the panel.
import { useEffect, useLayoutEffect, useRef, type RefObject } from "react";
import type { PageClient } from "../shared/pageClient";

export const CardOps = {
  /** `{card, height, width}` (CSS px) → null: the card's measured size. */
  resize: "cmux.card.resize",
  /** `{card}` → null: the card's Cancel or Done; the panel hides and the card's session ends. */
  close: "cmux.card.close",
  /** Stream: `{command: "cancel"}` when Escape reaches the panel outside the page. */
  commands: "cmux.card.commands",
} as const;

/** The card a hash names (`#/pair-invite` → `pair-invite`), or null. */
export function cardOfHash(hash: string): string | null {
  const match = /^#\/([a-z0-9-]+)/.exec(hash);
  return match ? match[1]! : null;
}

/** Reports `ref`'s size to the panel whenever it changes (the first layout included). A card's
 * click-only control (Confirm) is not the page's: the panel lays it out in its own native footer
 * under the page (WebCardPanel's PersonControl), so the size covers only the content above it. */
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

/** Runs `cancel` on Escape in the page and on the panel's own Escape. */
export function useCardCancel(client: PageClient | null, cancel: () => void): void {
  const latest = useRef(cancel);
  latest.current = cancel;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      latest.current();
    };
    document.addEventListener("keydown", onKey);
    let stop: (() => void) | undefined;
    let stopped = false;
    void client
      ?.subscribe<{ command?: string }>(CardOps.commands, (data) => {
        if (data?.command === "cancel") latest.current();
      })
      .then((unsubscribe) => (stopped ? unsubscribe() : (stop = unsubscribe)))
      .catch(() => {});
    return () => {
      stopped = true;
      document.removeEventListener("keydown", onKey);
      stop?.();
    };
  }, [client]);
}

/** Closes the card's panel (its Cancel or Done). */
export function closeCard(client: PageClient | null, card: string): void {
  void client?.call(CardOps.close, { card }).catch(() => {});
}
