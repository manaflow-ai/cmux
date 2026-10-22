// Owns when the delineated diff reorders: the file column goes into kind order once every file
// has arrived (code first, a lockfile never between two source files), and the file the reader is
// on stays under them across the reorder — in both directions, the toolbar's toggle included.
//
// The order of the two steps is the whole point and is easy to get wrong: the anchor is measured
// in the order on screen, and scrolled to only after the new order is in the DOM. That means a
// later commit, not `flushSync`: a passive effect already runs inside React's commit, where
// `flushSync` skips the flush and logs, so the scroll resolved against the old layout and dropped
// the reader onto an unrelated file — the very jump this hook exists to prevent (2026-10-20 review
// of #22951). `test/kind-order.test.tsx` pins measure-then-restore.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ItemScrollAnchor } from "./item-navigation";

/** What the viewer lends the hook to keep the reader's place. */
export type KindOrderHandlers = {
  /**
   * Where the reader is: the file under the viewport and how far into it, or `null` when they have
   * not scrolled into the diff. The offset is what keeps their line rather than their file.
   */
  anchor: () => ItemScrollAnchor | null;
  /** Puts that place back under the viewport, now that the column is in the new order. */
  restore: (anchor: ItemScrollAnchor) => void;
};

/**
 * Whether the file column reads in kind order. True once `enabled` and `ready` are both true, and
 * every change of it keeps the reader's place through `handlers`.
 *
 * - `ready`: the stream is complete. Grouping a diff that is still arriving would insert each new
 *   file into the middle of what the reader is reading.
 * - `enabled`: "Group files by kind" is on.
 */
export function useKindOrder({
  enabled,
  ready,
  handlers,
}: {
  enabled: boolean;
  ready: boolean;
  handlers: React.MutableRefObject<KindOrderHandlers>;
}): boolean {
  const target = enabled && ready;
  const [shown, setShown] = useState(target);
  const pending = useRef<ItemScrollAnchor | null>(null);
  useEffect(() => {
    if (shown === target) return;
    // Measured here, in the order the reader is looking at…
    pending.current = handlers.current.anchor();
    setShown(target);
  }, [handlers, shown, target]);
  // …and restored here, in the commit that reordered the column, before it is painted.
  useLayoutEffect(() => {
    const anchor = pending.current;
    if (anchor == null) return;
    pending.current = null;
    handlers.current.restore(anchor);
  }, [handlers, shown]);
  return shown;
}
