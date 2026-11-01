// Find in the changes view (cx-ncc.85, Claude parity): matches of a query in the diff's changed
// and context lines, the one the reader is on, and the highlights. The view renders every open
// file's rows (each in @pierre/diffs' open shadow root), so the rendered rows are the matches; a
// collapsed file's lines are not searched. The highlights are CSS custom highlights painted by the
// code view's painter (find/highlight.ts), which adopts their styles into the shadow roots.
import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from "react";
import { foldFind } from "../../../find/fold";
import { collectQueryRanges, installFindHighlightPainter, type FindHighlightPainter } from "../../../find/highlight";
import type { FindBarState } from "../conversation/chatFind";

/** The open changes view's find, for the page's Find commands: `owns` says whether they go to it
 * (the keyboard is in the view, or the view covers the transcript) rather than to the chat's. */
export type DiffFindHandle = { find: FindBarState; owns: () => boolean };

/** The find state of the changes view whose scrolling body is `body`. */
export function useDiffFind(body: RefObject<HTMLElement | null>): FindBarState {
  const [open, setOpen] = useState(false);
  const [query, setQueryState] = useState("");
  const [active, setActive] = useState(0);
  const [count, setCount] = useState(0);
  const [focusRequest, setFocusRequest] = useState(0);
  const current = count ? Math.min(active, count - 1) : 0;
  // What the painter reads on each pass, and the match it last scrolled to.
  const state = useRef({ query: "", active: 0 });
  state.current = { query: open ? foldFind(query) : "", active: current };
  const revealed = useRef("");
  const painter = useRef<FindHighlightPainter | undefined>(undefined);
  const opener = useRef<HTMLElement | null>(null);

  useEffect(() => {
    const container = body.current;
    if (!open || !container) return undefined;
    const installed = installFindHighlightPainter({
      container,
      getSnapshot: () => ({ query: state.current.query, active: null, activeItemSpan: null }),
      repaintOnScroll: false,
      collect: (root, snapshot, shadowRoots) => {
        const ranges = collectQueryRanges(root, snapshot.query, shadowRoots);
        setCount(ranges.length);
        const at = Math.min(state.current.active, ranges.length - 1);
        const activeRange = ranges[at];
        // Scroll to a new current match only, so a repaint never fights the reader's scrolling.
        const key = `${snapshot.query}\u0000${at}`;
        if (activeRange && revealed.current !== key) {
          revealed.current = key;
          const match = activeRange.getBoundingClientRect();
          const view = root.getBoundingClientRect();
          // The find bar floats over the top of the view.
          const top = view.top + (root.querySelector(".acpmux-find__bar")?.getBoundingClientRect().height ?? 0);
          if (match.top < top || match.bottom > view.bottom)
            root.scrollTop += match.top - view.top - (view.height - match.height) / 2;
          // A long unwrapped line scrolls sideways inside the diff.
          activeRange.startContainer.parentElement?.scrollIntoView({ block: "nearest", inline: "nearest" });
        }
        return {
          matchRanges: ranges.filter((range) => range !== activeRange),
          activeRanges: activeRange ? [activeRange] : [],
        };
      },
    });
    painter.current = installed;
    installed.repaint();
    return () => {
      installed.dispose();
      painter.current = undefined;
      revealed.current = "";
      setCount(0);
    };
  }, [open, body]);
  useEffect(() => {
    // An empty query paints nothing, so nothing counts it.
    if (!query) setCount(0);
    painter.current?.repaint();
  }, [query, current]);

  const show = useCallback((text?: string) => {
    const focused = document.activeElement;
    if (focused instanceof HTMLElement && !focused.closest(".acpmux-find")) opener.current = focused;
    setOpen(true);
    if (text) {
      setQueryState(text);
      setActive(0);
    }
    setFocusRequest((request) => request + 1);
  }, []);
  const hide = useCallback(() => {
    setOpen(false);
    const target = opener.current;
    opener.current = null;
    const focused = document.activeElement;
    const fromBar = !focused || focused === document.body || focused.closest(".acpmux-find");
    if (fromBar && target?.isConnected) target.focus({ preventScroll: true });
  }, []);
  const setQuery = useCallback((next: string) => {
    setQueryState(next);
    setActive(0);
  }, []);
  const step = useCallback(
    (by: number) => {
      if (!count) return;
      setOpen(true);
      setActive((index) => (Math.min(index, count - 1) + by + count) % count);
    },
    [count],
  );
  const next = useCallback(() => step(1), [step]);
  const previous = useCallback(() => step(-1), [step]);
  const matches = useMemo(() => Array.from({ length: open && query ? count : 0 }), [open, query, count]);
  return {
    open,
    query,
    matches,
    active: current,
    show,
    hide,
    setQuery,
    next,
    previous,
    focusRequest,
  };
}
