import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CodeViewHandle } from "@pierre/diffs/react";
import type { DiffItem } from "../diff-stream";
import { collectFindMatches, reanchorActiveMatch, type FindMatch } from "./model";
import {
  installFindHighlightPainter,
  type FindHighlightPainter,
  type FindPaintSnapshot,
} from "./highlight";

export type FindDispatch = React.Dispatch<
  | { type: "set-find-open"; open: boolean }
  | { type: "set-find-query"; query: string }
>;

type UseDiffFindOptions = {
  items: DiffItem[];
  open: boolean;
  query: string;
  dispatch: FindDispatch;
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>;
  viewerContainerRef: React.MutableRefObject<HTMLDivElement | null>;
};

export type DiffFindController = {
  matches: FindMatch[];
  activeIndex: number;
  activeMatch: FindMatch | null;
  setQuery: (query: string) => void;
  goToNext: () => void;
  goToPrevious: () => void;
  closeFind: () => void;
  /** Binds highlight-painter lifecycle to the find bar's mount. */
  findBarRef: (element: HTMLElement | null) => void;
};

/**
 * Owns diff find-in-page behavior: model-side match collection over the full
 * (virtualized) diff, active-match navigation via the code view's line
 * scrolling, and highlight painting over whatever rows are rendered.
 *
 * Contract: `open`/`query` state lives in the app reducer; this hook derives
 * matches, keeps the active index anchored while items stream in, jumps to
 * the first match when the QUERY changes, and repaints highlights. The
 * painter is installed while the find bar is mounted (`findBarRef`) and
 * disposed — clearing all highlights — when it unmounts.
 */
export function useDiffFind(options: UseDiffFindOptions): DiffFindController {
  const { items, open, query, dispatch, codeViewRef, viewerContainerRef } = options;

  const normalizedQuery = open ? query.toLowerCase() : "";
  const matches = useMemo(
    () => (normalizedQuery === "" ? [] : collectFindMatches(items, normalizedQuery)),
    [items, normalizedQuery],
  );

  const [activeIndex, setActiveIndex] = useState(0);
  const activeIndexRef = useRef(0);
  const activeMatchRef = useRef<FindMatch | null>(null);
  const lastQueryRef = useRef("");
  const painterRef = useRef<FindHighlightPainter | null>(null);
  const findBarMountedRef = useRef(false);
  const snapshotRef = useRef<FindPaintSnapshot>({ query: "", active: null, activeItemSpan: null });

  const clampedIndex = matches.length === 0 ? 0 : Math.min(activeIndex, matches.length - 1);
  const activeMatch = matches[clampedIndex] ?? null;

  const scrollToMatch = useCallback((match: FindMatch) => {
    codeViewRef.current?.scrollTo({
      type: "line",
      id: match.itemId,
      lineNumber: match.lineNumber,
      side: match.side,
      align: "center",
      behavior: "instant",
    });
  }, [codeViewRef]);

  const activeItemSpan = useCallback((match: FindMatch): { top: number; bottom: number } | null => {
    const instance = codeViewRef.current?.getInstance();
    if (instance == null) {
      return null;
    }
    const top = instance.getTopForItem(match.itemId);
    if (typeof top !== "number") {
      return null;
    }
    let bottom = Number.POSITIVE_INFINITY;
    const index = items.findIndex((item) => item.id === match.itemId);
    for (let i = index + 1; i >= 0 && i < items.length; i += 1) {
      const nextTop = instance.getTopForItem(items[i].id);
      if (typeof nextTop === "number" && nextTop > top) {
        bottom = nextTop;
        break;
      }
    }
    return { top, bottom };
  }, [codeViewRef, items]);

  // Reanchor the active index when the match list changes (query edits,
  // items streaming in). A QUERY change also jumps to its (re)anchored
  // match, like browser find while typing; item streaming only reanchors so
  // it never yanks the scroll position.
  useEffect(() => {
    const queryChanged = lastQueryRef.current !== normalizedQuery;
    lastQueryRef.current = normalizedQuery;
    const reanchored = reanchorActiveMatch(activeMatchRef.current, matches, activeIndexRef.current);
    if (reanchored !== activeIndexRef.current) {
      setActiveIndex(reanchored);
    }
    if (queryChanged) {
      const target = matches[reanchored];
      if (target != null) {
        scrollToMatch(target);
      }
    }
  }, [matches, normalizedQuery, scrollToMatch]);

  // Install the painter while the find bar is mounted AND the (lazily
  // created) scroll container exists. The container appears only after the
  // first diff items render, which can be after the bar opens, so the
  // publish effect below retries the install.
  const installPainterIfNeeded = useCallback(() => {
    if (!findBarMountedRef.current || painterRef.current != null) {
      return;
    }
    const container = viewerContainerRef.current;
    if (container == null) {
      return;
    }
    painterRef.current = installFindHighlightPainter({
      container,
      getSnapshot: () => snapshotRef.current,
    });
    painterRef.current.repaint();
  }, [viewerContainerRef]);

  // Publish what the painter reads and schedule a paint whenever the query
  // or the active match changes. Highlight changes are not DOM mutations, so
  // the painter's own observers cannot see them; this is the explicit nudge.
  useEffect(() => {
    activeIndexRef.current = clampedIndex;
    activeMatchRef.current = activeMatch;
    snapshotRef.current = {
      query: normalizedQuery,
      active: activeMatch,
      activeItemSpan: activeMatch == null ? null : activeItemSpan(activeMatch),
    };
    installPainterIfNeeded();
    painterRef.current?.repaint();
  }, [normalizedQuery, clampedIndex, activeMatch, activeItemSpan, installPainterIfNeeded]);

  const findBarRef = useCallback((element: HTMLElement | null) => {
    findBarMountedRef.current = element != null;
    if (element != null) {
      installPainterIfNeeded();
    } else {
      painterRef.current?.dispose();
      painterRef.current = null;
    }
  }, [installPainterIfNeeded]);

  const goTo = useCallback((index: number) => {
    const match = matches[index];
    if (match == null) {
      return;
    }
    setActiveIndex(index);
    scrollToMatch(match);
  }, [matches, scrollToMatch]);

  const goToNext = useCallback(() => {
    if (matches.length > 0) {
      goTo((activeIndexRef.current + 1) % matches.length);
    }
  }, [goTo, matches.length]);

  const goToPrevious = useCallback(() => {
    if (matches.length > 0) {
      goTo((activeIndexRef.current - 1 + matches.length) % matches.length);
    }
  }, [goTo, matches.length]);

  const setQuery = useCallback((nextQuery: string) => {
    dispatch({ type: "set-find-query", query: nextQuery });
  }, [dispatch]);

  const closeFind = useCallback(() => {
    dispatch({ type: "set-find-open", open: false });
  }, [dispatch]);

  return {
    matches,
    activeIndex: clampedIndex,
    activeMatch,
    setQuery,
    goToNext,
    goToPrevious,
    closeFind,
    findBarRef,
  };
}
