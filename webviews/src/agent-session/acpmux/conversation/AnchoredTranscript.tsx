// The anchored transcript (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 4), behind a
// flag: `#anchoredList=1` in the pane's URL or `localStorage["cmux.acpmux.anchoredList"] = "1"`. Off,
// VirtualTranscript draws as before; this list replaces only the part that decides where a row sits.
//
// One owner of geometry:
// - Heights live in a prefix-sum tree (anchoredListModel.ts), measured by one ResizeObserver and
//   kept by row id, so an older page or an append keeps every measured row's height.
// - The reader's place is an anchor, a row id and an offset. Every commit (a render, a measured
//   height, a resized viewport) restores it in the same frame, before paint: the layout effect after a
//   render and the ResizeObserver callback both run before the browser paints.
// - Following the latest is `pinned`, which only the reader's own scroll changes (reaching the end pins,
//   scrolling away unpins). While pinned the anchor is the last row's bottom edge, so a streamed token
//   restores it in the frame it lands: nothing chases and nothing springs.
// - Nothing that changes layout is animated, and the ScrollController is the only writer.
//
// What it leaves out for now (the old list still has them): Jump to latest, the minimaps, Find's
// reveal, keyboard row focus, the composer lift, entry and fold motion.
import React, { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { hasReplyActions, type AcpmuxRow } from "../model";
import { rowKind } from "../virtualTranscriptModel";
import { NoticeRow } from "../rows/NoticeRow";
import { defaultRegistry } from "../rows/registry";
import type { NativeRegistry, OpenDiff, RowProps } from "../rows/rowProps";
import { HeightIndex, anchorAt, heightsFor, offsetFor, windowAt, type Anchor } from "./anchoredListModel";
import { writeScrollTop } from "./scrollController";
import type { Folds } from "./viewFolds";

const FLAG_KEY = "cmux.acpmux.anchoredList";

/** Whether the anchored list draws the transcript instead of VirtualTranscript. */
export function anchoredListEnabled(): boolean {
  try {
    if (/(?:^|[#&])anchoredList=1(?:&|$)/.test(globalThis.location?.hash ?? "")) return true;
    return globalThis.localStorage?.getItem(FLAG_KEY) === "1";
  } catch {
    return false;
  }
}

/// A row's height before it is measured (the old list's estimate for a short row).
const ESTIMATE = 64;
/// The thread's top padding, as `.acpmux-thread` draws it.
const THREAD_TOP = 16;
/// Within this many px of the end, the reader is at the latest.
const PIN_SLOP = 2;
/// Ask for older history when the viewport's top comes within this many viewports of the first row.
const OLDER_VIEWPORTS = 2;

export type AnchoredTranscriptProps = {
  rows: readonly AcpmuxRow[];
  sessionId?: string;
  expanded: Folds;
  onToggleActivity: (id: string, covers?: readonly string[]) => void;
  onOpenDiff?: OpenDiff;
  registry?: NativeRegistry;
  githubRepository?: string;
  canLoadOlder?: boolean;
  onLoadOlder?: (fill: boolean, rising: boolean) => Promise<void>;
};

type RowViewProps = Omit<RowProps, "row"> & {
  row: AcpmuxRow;
  kind: string;
  top: number;
  Component: React.ComponentType<RowProps>;
  observe: (node: HTMLElement | null, id: string) => void;
};

const RowView = React.memo(function RowView({ row, kind, top, Component, observe, ...props }: RowViewProps) {
  const ref = useCallback((node: HTMLElement | null) => observe(node, row.id), [observe, row.id]);
  return (
    <div ref={ref} className={`acpmux-row acpmux-${kind}`} data-row-id={row.id} style={{ top }}>
      <Component row={row} {...props} />
    </div>
  );
});

export function AnchoredTranscript({
  rows,
  sessionId,
  expanded,
  onToggleActivity,
  onOpenDiff,
  registry = defaultRegistry,
  githubRepository,
  canLoadOlder = false,
  onLoadOlder,
}: AnchoredTranscriptProps) {
  const scroller = useRef<HTMLDivElement>(null);
  const spacer = useRef<HTMLDivElement>(null);
  const measured = useRef(new Map<string, number>());
  const anchor = useRef<Anchor | undefined>(undefined);
  const pinned = useRef(true);
  // The offset the controller last wrote: its scroll event is ours, not the reader's.
  const wrote = useRef<number | undefined>(undefined);
  const loadingOlder = useRef(false);
  const nodes = useRef(new Map<string, HTMLElement>());
  const [view, setView] = useState({ top: 0, height: 0 });

  const ids = useMemo(() => rows.map((row) => row.id), [rows]);
  const position = useMemo(() => new Map(ids.map((id, index) => [id, index])), [ids]);
  // Rebuilt when the rows change (O(n), a few ms at 50k rows); a height change is O(log n).
  const index = useMemo(() => new HeightIndex(heightsFor(ids, measured.current, ESTIMATE)), [ids]);
  const indexRef = useRef(index);
  indexRef.current = index;
  const positionRef = useRef(position);
  positionRef.current = position;
  const idsRef = useRef(ids);
  idsRef.current = ids;

  /** Puts the reader back: the anchor's offset, or the end while pinned. */
  const restore = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    const total = indexRef.current.total();
    if (spacer.current) spacer.current.style.height = `${THREAD_TOP + total}px`;
    // Row space starts under the thread's top padding; the scroller's offset counts it.
    const target =
      THREAD_TOP +
      offsetFor(indexRef.current, positionRef.current, anchor.current, pinned.current, node.clientHeight - THREAD_TOP);
    if (Math.abs(node.scrollTop - target) < 0.5) return;
    wrote.current = target;
    writeScrollTop(node, target, "anchor");
  }, []);

  /**
   * One commit: measure the mounted rows (every read before any write), move the rows under the
   * first one that changed, and restore the reader's place. It runs where a change lands, before
   * anything can read or paint the state in between: the layout effect after a render, the
   * MutationObserver's microtask after a row's own render (a streamed token that never passed
   * through this list), and the ResizeObserver for late changes (a font, an image).
   */
  const commit = useCallback(() => {
    const heights = indexRef.current;
    const reads: [number, number, string][] = [];
    for (const [id, node] of nodes.current) {
      const at = positionRef.current.get(id);
      if (at !== undefined) reads.push([at, node.getBoundingClientRect().height, id]);
    }
    let first = Infinity;
    for (const [at, height, id] of reads) {
      if (height <= 0) continue;
      measured.current.set(id, height);
      if (heights.set(at, height) !== 0) first = Math.min(first, at);
    }
    if (first !== Infinity)
      for (const [id, node] of nodes.current) {
        const at = positionRef.current.get(id);
        if (at !== undefined && at > first) node.style.top = `${THREAD_TOP + heights.top(at)}px`;
      }
    restore();
  }, [restore]);

  // One observer for every mounted row and the scroller itself (the composer's growth shrinks it).
  const observer = useMemo(
    () => (typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(commit)),
    [commit],
  );

  const observe = useCallback(
    (node: HTMLElement | null, id: string) => {
      const before = nodes.current.get(id);
      if (before && before !== node) {
        observer?.unobserve(before);
        nodes.current.delete(id);
      }
      if (node) {
        nodes.current.set(id, node);
        observer?.observe(node);
      }
    },
    [observer],
  );

  // Every render commits before the frame paints.
  useLayoutEffect(commit);

  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node || !observer) return;
    observer.observe(node);
    // A row that renders on its own (streamed text reaches its row without this list) commits in
    // the same task, at the microtask after its DOM changed.
    const mutations = typeof MutationObserver === "undefined" ? undefined : new MutationObserver(commit);
    if (spacer.current) mutations?.observe(spacer.current, { subtree: true, childList: true, characterData: true });
    setView({ top: node.scrollTop, height: node.clientHeight });
    return () => {
      observer.disconnect();
      mutations?.disconnect();
    };
  }, [observer, commit]);

  const onScroll = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    const top = node.scrollTop;
    const ours = wrote.current !== undefined && Math.abs(top - wrote.current) < 1;
    wrote.current = undefined;
    if (!ours) {
      pinned.current = node.scrollHeight - node.clientHeight - top <= PIN_SLOP;
      anchor.current = pinned.current ? undefined : anchorAt(indexRef.current, idsRef.current, top - THREAD_TOP);
    }
    setView((was) => (was.top === top && was.height === node.clientHeight ? was : { top, height: node.clientHeight }));
    if (canLoadOlder && onLoadOlder && !loadingOlder.current && top < node.clientHeight * OLDER_VIEWPORTS) {
      loadingOlder.current = true;
      void onLoadOlder(false, true).finally(() => (loadingOlder.current = false));
    }
  }, [canLoadOlder, onLoadOlder]);

  // A click on a row (a fold's header) makes that row the anchor, so it stays under the pointer.
  const onPointerDown = useCallback((event: React.PointerEvent) => {
    const node = scroller.current;
    const row = (event.target as HTMLElement).closest<HTMLElement>(".acpmux-row[data-row-id]");
    if (!node || !row || pinned.current) return;
    const at = positionRef.current.get(row.dataset.rowId!);
    if (at === undefined) return;
    anchor.current = { id: row.dataset.rowId!, offset: node.scrollTop - THREAD_TOP - indexRef.current.top(at) };
  }, []);

  const { first, last } = windowAt(index, Math.max(0, view.top - THREAD_TOP), view.height || 800);
  const mounted: React.ReactElement[] = [];
  for (let at = first; at < last; at++) {
    const row = rows[at]!;
    const kind = rowKind(row);
    mounted.push(
      <RowView
        key={row.id}
        row={row}
        kind={kind}
        top={THREAD_TOP + index.top(at)}
        Component={registry[kind] ?? NoticeRow}
        observe={observe}
        replyActions={hasReplyActions(row, rows[at + 1])}
        sessionId={sessionId}
        onToggleActivity={onToggleActivity}
        onOpenDiff={onOpenDiff}
        expanded={row.foldOpen ?? expanded.has(row.id)}
        githubRepository={githubRepository}
      />,
    );
  }
  return (
    <div
      ref={scroller}
      className="acpmux-scroll acpmux-scroll--anchored"
      style={{ overflowAnchor: "none" }}
      onScroll={onScroll}
      onPointerDownCapture={onPointerDown}
      data-anchored-list=""
    >
      <div ref={spacer} className="acpmux-spacer" style={{ height: THREAD_TOP + index.total() }}>
        {mounted}
      </div>
    </div>
  );
}
