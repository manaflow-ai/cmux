// The anchored transcript (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 4), behind a
// flag: `#anchoredList=1` in the pane's URL or `localStorage["cmux.acpmux.anchoredList"] = "1"`. Off,
// VirtualTranscript draws as before; this list replaces only the part that decides where a row sits.
//
// One owner of geometry:
// - Heights live in a prefix-sum tree (anchoredListModel.ts), measured by one ResizeObserver and
//   cached by row id, content hash and width (HeightCache), so an older page or an append keeps every
//   measured row's height, and a reopened fold or a width it was drawn at before is exact at once.
// - The reader's place is an anchor, a row id and an offset. Every commit (a render, a measured
//   height, a resized viewport) restores it in the same frame, before paint: the layout effect after a
//   render and the ResizeObserver callback both run before the browser paints.
// - Following the latest is `pinned`, which only the reader's own scroll changes (reaching the end pins,
//   scrolling away unpins). While pinned the anchor is the last row's bottom edge, so a streamed token
//   restores it in the frame it lands: nothing chases and nothing springs.
// - Nothing that changes layout is animated, and the ScrollController is the only writer.
//
// What it leaves out for now (the old list still has them): the minimaps, Find's reveal,
// keyboard row focus, Jump up and the Needs your input pill, the composer lift, entry and fold motion.
import React, { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { hasReplyActions, type AcpmuxRow } from "../model";
import { rowKind } from "../virtualTranscriptModel";
import { NoticeRow } from "../rows/NoticeRow";
import { defaultRegistry } from "../rows/registry";
import type { NativeRegistry, OpenDiff, RowProps } from "../rows/rowProps";
import {
  HeightCache,
  HeightIndex,
  anchorAt,
  heightsFor,
  offsetFor,
  rowContentHash,
  windowAt,
  type Anchor,
} from "./anchoredListModel";
import { focusRoute } from "../../../ui/focusRoute";
import { useT } from "../i18n";
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
  /** The composer's stack, which floats over the scroller's foot: the last row ends above it. */
  dock?: HTMLElement | null;
  /** Whether the pane draws Jump to latest, and the agent is still working (its label). */
  jumpButton?: boolean;
  working?: boolean;
  /** VirtualTranscript's JumpToLatest, passed in so this file does not import the old list. */
  JumpButton?: React.ComponentType<{
    shown: boolean;
    working: boolean;
    lift: number;
    onJump: (focused: boolean) => void;
  }>;
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
  dock,
  jumpButton = false,
  working = false,
  JumpButton,
}: AnchoredTranscriptProps) {
  const t = useT();
  const scroller = useRef<HTMLDivElement>(null);
  const spacer = useRef<HTMLDivElement>(null);
  // Another chat's rows share no heights with this one's.
  const measured = useMemo(() => new HeightCache(sessionId), [sessionId]);
  const anchor = useRef<Anchor | undefined>(undefined);
  const pinned = useRef(true);
  // The offset the controller last wrote: its scroll event is ours, not the reader's.
  const wrote = useRef<number | undefined>(undefined);
  const loadingOlder = useRef(false);
  const nodes = useRef(new Map<string, HTMLElement>());
  // How far the composer's stack reaches over the scroller, measured with the rows in each commit.
  const reserve = useRef(0);
  // The same reserve, for render: the spacer's height and the jump button's lift.
  const [lift, setLift] = useState(0);
  const dockRef = useRef(dock);
  const [view, setView] = useState({ top: 0, height: 0, width: 0 });
  // Whether the reader is away from the latest (Jump to latest shows); set only by their own scroll.
  const [behind, setBehind] = useState(false);

  const ids = useMemo(() => rows.map((row) => row.id), [rows]);
  const position = useMemo(() => new Map(ids.map((id, index) => [id, index])), [ids]);
  // What each row's height depends on besides the width: its version, its fold, its reply actions.
  const keyed = useMemo(
    () =>
      rows.map((row, at) => ({
        id: row.id,
        hash: rowContentHash(row.version, row.foldOpen ?? expanded.has(row.id), hasReplyActions(row, rows[at + 1])),
      })),
    [rows, expanded],
  );
  const hashes = useMemo(() => new Map(keyed.map(({ id, hash }) => [id, hash])), [keyed]);
  const hashesRef = useRef(hashes);
  const width = view.width;
  const widthRef = useRef(width);
  // Rebuilt when the rows, a row's content or the width change (O(n), a few ms at 50k rows); a
  // measured height change is O(log n).
  const index = useMemo(() => new HeightIndex(heightsFor(keyed, measured, width, ESTIMATE)), [keyed, measured, width]);
  const indexRef = useRef(index);
  const positionRef = useRef(position);
  const idsRef = useRef(ids);
  // The callbacks below read this render's values; written before any other effect runs (effects run in
  // order), never during render, so the React Compiler keeps this component.
  useLayoutEffect(() => {
    dockRef.current = dock;
    hashesRef.current = hashes;
    widthRef.current = width;
    indexRef.current = index;
    positionRef.current = position;
    idsRef.current = ids;
  });

  /** Puts the reader back: the anchor's offset, or the end while pinned. */
  const restore = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    const total = indexRef.current.total();
    if (spacer.current) spacer.current.style.height = `${THREAD_TOP + total + reserve.current}px`;
    // Row space starts under the thread's top padding; the scroller's offset counts it.
    const target =
      THREAD_TOP +
      offsetFor(
        indexRef.current,
        positionRef.current,
        anchor.current,
        pinned.current,
        node.clientHeight - THREAD_TOP - reserve.current,
      );
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
    const stack = dockRef.current?.getBoundingClientRect();
    const view = scroller.current?.getBoundingClientRect();
    // Heights are kept per width: a new width renders again with the heights known at it.
    const width = Math.round(scroller.current?.clientWidth ?? 0);
    if (width !== widthRef.current) {
      widthRef.current = width;
      setView((was) => (was.width === width ? was : { ...was, width }));
    }
    const covered =
      stack && view && stack.height > 0 ? Math.max(0, Math.min(stack.height, view.bottom - stack.top)) : 0;
    reserve.current = covered;
    setLift((was) => (was === covered ? was : covered));
    const reads: [number, number, string][] = [];
    for (const [id, node] of nodes.current) {
      const at = positionRef.current.get(id);
      if (at !== undefined) reads.push([at, node.getBoundingClientRect().height, id]);
    }
    let first = Infinity;
    for (const [at, height, id] of reads) {
      if (height <= 0) continue;
      measured.set(id, hashesRef.current.get(id) ?? 0, widthRef.current, height);
      if (heights.set(at, height) !== 0) first = Math.min(first, at);
    }
    if (first !== Infinity)
      for (const [id, node] of nodes.current) {
        const at = positionRef.current.get(id);
        if (at !== undefined && at > first) node.style.top = `${THREAD_TOP + heights.top(at)}px`;
      }
    restore();
  }, [restore, measured]);
  const commitRef = useRef(commit);
  useLayoutEffect(() => {
    commitRef.current = commit;
  });

  // One observer for every mounted row and the scroller itself (the composer's growth shrinks it).
  // Made on first use, never during render; it commits through commitRef, so it outlives a new chat's commit.
  const observerRef = useRef<ResizeObserver | undefined>(undefined);
  const observerOf = useCallback(() => {
    if (!observerRef.current && typeof ResizeObserver !== "undefined")
      observerRef.current = new ResizeObserver(() => commitRef.current());
    return observerRef.current;
  }, []);

  const observe = useCallback(
    (node: HTMLElement | null, id: string) => {
      const observer = observerOf();
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
    [observerOf],
  );

  // Every render commits before the frame paints.
  useLayoutEffect(commit);

  useLayoutEffect(() => {
    const node = scroller.current;
    const observer = observerOf();
    if (!node || !observer) return;
    observer.observe(node);
    if (dock) observer.observe(dock);
    // A row that renders on its own (streamed text reaches its row without this list) commits in
    // the same task, at the microtask after its DOM changed.
    const mutations = typeof MutationObserver === "undefined" ? undefined : new MutationObserver(commit);
    if (spacer.current) mutations?.observe(spacer.current, { subtree: true, childList: true, characterData: true });
    setView({ top: node.scrollTop, height: node.clientHeight, width: Math.round(node.clientWidth) });
    return () => {
      // The rows' observations stay: the observer outlives this effect (observerOf).
      observer.unobserve(node);
      if (dock) observer.unobserve(dock);
      mutations?.disconnect();
    };
  }, [observerOf, commit, dock]);
  useLayoutEffect(() => () => observerRef.current?.disconnect(), []);

  const onScroll = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    const top = node.scrollTop;
    const ours = wrote.current !== undefined && Math.abs(top - wrote.current) < 1;
    wrote.current = undefined;
    if (!ours) {
      pinned.current = node.scrollHeight - node.clientHeight - top <= PIN_SLOP;
      anchor.current = pinned.current ? undefined : anchorAt(indexRef.current, idsRef.current, top - THREAD_TOP);
      setBehind(!pinned.current);
    }
    setView((was) =>
      was.top === top && was.height === node.clientHeight ? was : { ...was, top, height: node.clientHeight },
    );
    if (canLoadOlder && onLoadOlder && !loadingOlder.current && top < node.clientHeight * OLDER_VIEWPORTS) {
      loadingOlder.current = true;
      void onLoadOlder(false, true).finally(() => (loadingOlder.current = false));
    }
  }, [canLoadOlder, onLoadOlder]);

  /** Back to the latest: pinned again, in one write (no glide: nothing that changes layout animates). */
  const toLatest = useCallback(() => {
    pinned.current = true;
    anchor.current = undefined;
    setBehind(false);
    restore();
  }, [restore]);

  // End or Cmd-Down (without Shift) goes to the latest, as in the old list.
  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.shiftKey || !(event.key === "End" || (event.metaKey && event.key === "ArrowDown"))) return;
      event.preventDefault();
      toLatest();
    };
    node.addEventListener("keydown", onKey);
    return () => node.removeEventListener("keydown", onKey);
  }, [toLatest]);

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
    <>
      <div
        ref={scroller}
        className="acpmux-scroll acpmux-scroll--anchored"
        role="feed"
        aria-label={t("transcript.label")}
        // Focusable, so End and Cmd-Down reach it, as on the old list.
        tabIndex={-1}
        style={{ overflowAnchor: "none" }}
        onScroll={onScroll}
        onPointerDownCapture={onPointerDown}
        data-anchored-list=""
      >
        <div ref={spacer} className="acpmux-spacer" style={{ height: THREAD_TOP + index.total() + lift }}>
          {mounted}
        </div>
      </div>
      {/* Next to the scroller, as in the old list: inside it, `bottom` is the scrolled content's end. */}
      {jumpButton && JumpButton && (
        <JumpButton
          shown={behind}
          working={working}
          lift={lift}
          onJump={(focused) => {
            toLatest();
            // The button hides at the latest; keyboard focus goes to the list, not to the body.
            if (focused)
              focusRoute(scroller.current, "person", "Jump to latest pressed by keyboard", { preventScroll: true });
          }}
        />
      )}
    </>
  );
}
