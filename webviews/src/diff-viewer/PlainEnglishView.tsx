// Plain English: the diff read as sentences. Each hunk is one row, the sentence an agent wrote
// for it (hunkSummaries.ts), with its code folded beneath; a click unfolds the code. Rows only
// ask for a sentence while they are on screen or within a screen of it (one
// IntersectionObserver over the mounted rows), so a 40-file change costs the hunks you look at.
//
// The view is windowed (TanStack Virtual): only the file paths and rows near the viewport, about
// one viewport each side, are mounted, plus the row that holds focus. The mounted items of one file
// stay one `<section>` with its `<h3>` and `<ol>`, placed at the first one's offset, so the page
// reads as before. Rows are memoized on their hunk, place and fold, so a sentence arriving, a
// scroll step or a fold draws only the rows it changed.
//
// A row's height is fixed before its sentence comes: while it loads the row shows the hunk's
// first changed line in the same box, and the sentence slides in over it, so nothing above or
// below moves and the scroll position stays put. Reduce Motion fades it in without the slide.
import { PatchDiff } from "@pierre/diffs/react";
import { defaultRangeExtractor, useVirtualizer, type Range, type VirtualItem } from "@tanstack/react-virtual";
import { memo, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Icon } from "../icons";
import type { DiffViewerLabelResolver } from "../labels";
import { type HunkRef, hunkRefs, type SummaryFileDiff, type SummaryState, type SummaryStore } from "./hunkSummaries";

/** How far past the window a row still asks: one screen above and below. */
const NEAR = "100% 0px 100% 0px";

/** Sizes before the first item of a kind is measured (styles.css): a path, a folded row. */
const PATH_ESTIMATE = 24;
const ROW_ESTIMATE = 54;
/** An unfolded hunk adds its code (Pierre's 20 px lines) and the Open in diff button. */
const CODE_LINE_ESTIMATE = 20;
const CODE_CHROME_ESTIMATE = 40;
/** The list's own top and bottom space (styles.css pads only its sides). */
const PADDING_START = 12;
const PADDING_END = 32;

export type PlainEnglishFile = { itemId: string; fileDiff: SummaryFileDiff };

export type PlainEnglishViewProps = {
  files: readonly PlainEnglishFile[];
  store: SummaryStore;
  label: DiffViewerLabelResolver;
  /** The code view's Pierre options (theme, wrap, line numbers) for an unfolded hunk. */
  codeOptions?: Record<string, unknown>;
  /** Back to the code view at this hunk. */
  onOpenInDiff?: (ref: HunkRef) => void;
};

/** One windowed item: a file's path, or one of its hunks (`position` is its 1-based place in the file). */
type Item =
  | { kind: "path"; file: string; path: string; first: boolean }
  | { kind: "hunk"; file: string; ref: HunkRef; position: number; count: number; last: boolean };

/** The kinds of item whose folded heights differ (styles.css). */
type SizeKind = "path" | "path-first" | "hunk" | "hunk-last";
const sizeKind = (item: Item): SizeKind =>
  item.kind === "path" ? (item.first ? "path-first" : "path") : item.last ? "hunk-last" : "hunk";

type Model = {
  items: Item[];
  /** Every hunk in reading order: the store's queue is drawn from these. */
  order: HunkRef[];
  /** Hunk id to its item index and its place in `order`: a lookup, never a scan. */
  place: Map<string, { item: number; order: number }>;
};

// A file's hunks are built once per parsed diff: a stream or refresh that keeps a file keeps its
// hunk objects, so its memoized rows do not draw again.
const refsByDiff = new WeakMap<SummaryFileDiff, { itemId: string; refs: HunkRef[] }>();
function refsOf(file: PlainEnglishFile): HunkRef[] {
  const held = refsByDiff.get(file.fileDiff);
  if (held && held.itemId === file.itemId) return held.refs;
  const refs = hunkRefs(file.itemId, file.fileDiff);
  refsByDiff.set(file.fileDiff, { itemId: file.itemId, refs });
  return refs;
}

/** Built once per diff, not per render, scroll or sentence. */
function buildModel(files: readonly PlainEnglishFile[]): Model {
  const items: Item[] = [];
  const order: HunkRef[] = [];
  const place = new Map<string, { item: number; order: number }>();
  for (const file of files) {
    const refs = refsOf(file);
    if (refs.length === 0) continue;
    items.push({ kind: "path", file: file.itemId, path: refs[0]!.path, first: items.length === 0 });
    refs.forEach((ref, index) => {
      place.set(ref.id, { item: items.length, order: order.length });
      order.push(ref);
      items.push({
        kind: "hunk",
        file: file.itemId,
        ref,
        position: index + 1,
        count: refs.length,
        last: index === refs.length - 1,
      });
    });
  }
  return { items, order, place };
}

/** An unfolded hunk's code lines: its patch without the `@@` header. */
const codeLines = (ref: HunkRef) => ref.patch.split("\n").length - 1;

export function PlainEnglishView({ files, store, label, codeOptions, onOpenInDiff }: PlainEnglishViewProps) {
  const model = useMemo(() => buildModel(files), [files]);
  const scroller = useRef<HTMLDivElement | null>(null);
  const observe = useNearWindow(scroller, model, store);
  // Which hunks show their code: kept here, not in the row, so a row scrolled away and back keeps it.
  const [unfolded, setUnfolded] = useState<ReadonlySet<string>>(() => new Set());
  const toggle = useCallback(
    (id: string) =>
      setUnfolded((shown) => {
        const next = new Set(shown);
        if (!next.delete(id)) next.add(id);
        return next;
      }),
    [],
  );
  // The row that holds focus stays mounted however far the view scrolls: keys still reach it.
  const [focusedId, setFocusedId] = useState<string | undefined>(undefined);
  const focusedItem = focusedId === undefined ? -1 : (model.place.get(focusedId)?.item ?? -1);
  // One function per diff: TanStack measures every item again when it changes.
  const itemKey = useCallback(
    (index: number) => {
      const item = model.items[index]!;
      return item.kind === "path" ? `path:${item.file}` : item.ref.id;
    },
    [model],
  );
  // The first mounted item of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N items again whenever a measure differs.
  const sizes = useRef(new Map<SizeKind, number>());
  const unfoldedRef = useRef(unfolded);
  // react-doctor-disable-next-line react-doctor/no-ref-current-in-render -- estimateSize reads it while TanStack measures in this render; an effect would hand it the last render's set.
  unfoldedRef.current = unfolded;
  const estimateSize = useCallback(
    (index: number) => {
      const item = model.items[index]!;
      const kind = sizeKind(item);
      const folded = sizes.current.get(kind) ?? (item.kind === "path" ? PATH_ESTIMATE : ROW_ESTIMATE);
      if (item.kind === "path" || !unfoldedRef.current.has(item.ref.id)) return folded;
      return folded + 1 + codeLines(item.ref) * CODE_LINE_ESTIMATE + CODE_CHROME_ESTIMATE;
    },
    [model],
  );
  const viewport = useRef(0);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns a mutable instance, so the React Compiler skips this component, as in ui/VirtualList.
  const virtualizer = useVirtualizer({
    count: model.items.length,
    getScrollElement: () => scroller.current,
    estimateSize,
    getItemKey: itemKey,
    // About one viewport of rows above and below the visible ones.
    overscan: Math.max(8, Math.ceil((viewport.current || 800) / (sizes.current.get("hunk") ?? ROW_ESTIMATE))),
    paddingStart: PADDING_START,
    paddingEnd: PADDING_END,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (focusedItem >= 0 && !indexes.includes(focusedItem)) {
        indexes.push(focusedItem);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
    onChange: (instance) => {
      viewport.current = instance.scrollRect?.height ?? viewport.current;
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      const kind = node?.dataset.size as SizeKind | undefined;
      if (node && kind && !sizes.current.has(kind) && node.offsetHeight > 0) sizes.current.set(kind, node.offsetHeight);
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );

  // The mounted items, one run per file: a run is drawn as that file's section, at its first offset.
  const virtualItems = virtualizer.getVirtualItems();
  const runs: { file: string; items: VirtualItem[] }[] = [];
  for (const placed of virtualItems) {
    const run = runs.at(-1);
    const file = model.items[placed.index]!.file;
    if (run && run.file === file && run.items.at(-1)!.index === placed.index - 1) run.items.push(placed);
    else runs.push({ file, items: [placed] });
  }
  // A file's section keeps its key as the window moves, so its rows stay mounted, not drawn anew.
  // Only while the focused row is kept apart from the window in the same file are there two: the
  // focused row's keeps the file's key (its row keeps focus), the window's is the file's second.
  const split = focusedItem >= 0 ? model.items[focusedItem]!.file : undefined;
  const runKey = (file: string, first: number, last: number) =>
    file === split &&
    (focusedItem < first || focusedItem > last) &&
    runs.some(
      (run) => run.file === file && run.items[0]!.index <= focusedItem && run.items.at(-1)!.index >= focusedItem,
    )
      ? `${file}~window`
      : file;

  return (
    <div
      className="plain-english"
      ref={scroller}
      aria-label={label("plainEnglish")}
      onFocus={(event) =>
        setFocusedId((event.target as HTMLElement).closest<HTMLElement>("[data-hunk-id]")?.dataset.hunkId)
      }
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocusedId(undefined);
      }}
    >
      <div className="plain-english-space" style={{ height: virtualizer.getTotalSize() }}>
        {runs.map(({ file, items }) => {
          const first = items[0]!;
          const last = items.at(-1)!;
          const head = model.items[first.index]!;
          const hunks = head.kind === "path" ? items.slice(1) : items;
          const firstHunk = hunks[0] ? model.items[hunks[0].index] : undefined;
          return (
            <section
              key={runKey(file, first.index, last.index)}
              className="plain-english-file"
              style={{ transform: `translateY(${first.start}px)` }}
            >
              {head.kind === "path" ? (
                <FilePath index={first.index} path={head.path} first={head.first} measure={measure} />
              ) : null}
              {hunks.length > 0 ? (
                <ol className="plain-english-hunks" start={firstHunk?.kind === "hunk" ? firstHunk.position : undefined}>
                  {hunks.map(({ index }) => {
                    const item = model.items[index] as Extract<Item, { kind: "hunk" }>;
                    return (
                      <HunkSentence
                        key={item.ref.id}
                        index={index}
                        hunk={item.ref}
                        position={item.position}
                        count={item.count}
                        last={item.last}
                        open={unfolded.has(item.ref.id)}
                        onToggle={toggle}
                        store={store}
                        label={label}
                        observe={observe}
                        measure={measure}
                        codeOptions={codeOptions}
                        onOpenInDiff={onOpenInDiff}
                      />
                    );
                  })}
                </ol>
              ) : null}
            </section>
          );
        })}
      </div>
    </div>
  );
}

const FilePath = memo(function FilePath({
  index,
  path,
  first,
  measure,
}: {
  index: number;
  path: string;
  first: boolean;
  measure: (element: HTMLElement | null) => void;
}) {
  return (
    <h3
      ref={measure}
      data-index={index}
      data-size={first ? "path-first" : "path"}
      data-first={first || undefined}
      className="plain-english-path"
    >
      {path}
    </h3>
  );
});

/**
 * One IntersectionObserver over the view's mounted rows: the hunks in or within a screen of the
 * window, in reading order, become the store's queue each frame they change. Disconnects on unmount.
 */
function useNearWindow(
  scroller: React.RefObject<HTMLDivElement | null>,
  model: Model,
  store: SummaryStore,
): (element: HTMLElement | null, id: string) => void {
  const near = useRef(new Set<string>());
  const elements = useRef(new Map<string, HTMLElement>());
  const modelRef = useRef(model);
  modelRef.current = model;
  const frame = useRef(0);
  const observer = useRef<IntersectionObserver | null>(null);
  const publish = useCallback(() => {
    if (frame.current) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = 0;
      // The near rows sorted by their place: as many as are mounted, never the whole diff.
      const { order, place } = modelRef.current;
      const places: number[] = [];
      for (const id of near.current) {
        const at = place.get(id);
        if (at) places.push(at.order);
      }
      places.sort((a, b) => a - b);
      store.want(places.map((at) => order[at]!));
    });
  }, [store]);
  useEffect(() => {
    const root = scroller.current;
    if (!root || typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = (entry.target as HTMLElement).dataset.hunkId;
          if (!id) continue;
          if (entry.isIntersecting) near.current.add(id);
          else near.current.delete(id);
        }
        publish();
      },
      { root, rootMargin: NEAR },
    );
    observer.current = io;
    for (const element of elements.current.values()) io.observe(element);
    return () => {
      io.disconnect();
      observer.current = null;
      if (frame.current) cancelAnimationFrame(frame.current);
      frame.current = 0;
    };
  }, [publish, scroller]);
  // A new diff keeps the rows still in it near; the queue follows the new order.
  useEffect(() => publish(), [model, publish]);
  return useCallback(
    (element: HTMLElement | null, id: string) => {
      const previous = elements.current.get(id);
      if (previous && previous !== element) {
        observer.current?.unobserve(previous);
        elements.current.delete(id);
        // A row scrolled out of the window is no longer near: its ask leaves the queue.
        if (near.current.delete(id)) publish();
      }
      if (element) {
        elements.current.set(id, element);
        observer.current?.observe(element);
      }
    },
    [publish],
  );
}

function useSummary(store: SummaryStore, key: string): SummaryState {
  const subscribe = useCallback((listener: () => void) => store.subscribe(key, listener), [store, key]);
  const read = useCallback(() => store.get(key), [store, key]);
  return useSyncExternalStore(subscribe, read, read);
}

const HunkSentence = memo(function HunkSentence({
  index,
  hunk,
  position,
  count,
  last,
  open,
  onToggle,
  store,
  label,
  observe,
  measure,
  codeOptions,
  onOpenInDiff,
}: {
  /** Its place among the windowed items: TanStack measures it by `data-index`. */
  index: number;
  hunk: HunkRef;
  /** 1-based place among its file's hunks, and their count: the screen reader's "3 of 10". */
  position: number;
  count: number;
  last: boolean;
  open: boolean;
  onToggle: (id: string) => void;
  store: SummaryStore;
  label: DiffViewerLabelResolver;
  observe: (element: HTMLElement | null, id: string) => void;
  measure: (element: HTMLElement | null) => void;
  codeOptions?: Record<string, unknown>;
  onOpenInDiff?: (ref: HunkRef) => void;
}) {
  const state = useSummary(store, hunk.key);
  // A sentence already known when the row mounts is drawn in place; one that comes while the row
  // shows slides in.
  const [arrives] = useState(() => state.kind === "loading");
  const ref = useCallback(
    (element: HTMLLIElement | null) => {
      observe(element, hunk.id);
      measure(element);
    },
    [observe, measure, hunk.id],
  );
  const codeId = `${hunk.id}-code`;
  return (
    <li
      className="plain-english-hunk"
      data-hunk-id={hunk.id}
      data-index={index}
      // An unfolded row is sized by its code, not by the folded rows' kind.
      data-size={open ? undefined : last ? "hunk-last" : "hunk"}
      data-first={position === 1 || undefined}
      data-last={last || undefined}
      aria-posinset={position}
      aria-setsize={count}
      ref={ref}
    >
      <button
        type="button"
        className="plain-english-row"
        data-state={state.kind}
        data-arrives={arrives || undefined}
        aria-expanded={open}
        aria-controls={open ? codeId : undefined}
        aria-busy={state.kind === "loading" || undefined}
        onClick={() => onToggle(hunk.id)}
      >
        <Icon name={open ? "chevronDown" : "chevronRight"} />
        <span className="plain-english-text">
          {/* Both sit in one grid cell: the sentence takes the preview's place, never its height. */}
          <code className="plain-english-preview" aria-hidden={state.kind === "ready" || undefined}>
            {hunk.preview}
          </code>
          {state.kind === "ready" ? (
            <span className="plain-english-sentence">{state.text}</span>
          ) : state.kind === "failed" ? (
            <span className="plain-english-sentence plain-english-failed">{label("hunkSummaryFailed")}</span>
          ) : (
            <span className="visually-hidden">{label("hunkSummaryLoading")}</span>
          )}
        </span>
        <span className="plain-english-stats" aria-hidden="true">
          {hunk.additions > 0 ? <span className="plain-english-added">+{hunk.additions}</span> : null}
          {hunk.deletions > 0 ? <span className="plain-english-removed">−{hunk.deletions}</span> : null}
        </span>
      </button>
      {open ? (
        <div className="plain-english-code" id={codeId}>
          <HunkCode hunk={hunk} codeOptions={codeOptions} />
          {onOpenInDiff ? (
            <button type="button" className="plain-english-open" onClick={() => onOpenInDiff(hunk)}>
              {label("hunkSummaryOpenInDiff")}
            </button>
          ) : null}
        </div>
      ) : null}
    </li>
  );
});

/** The hunk's own code, drawn by Pierre as a one-hunk patch, only while unfolded. */
function HunkCode({ hunk, codeOptions }: { hunk: HunkRef; codeOptions?: Record<string, unknown> }) {
  const patch = useMemo(
    () => `diff --git a/${hunk.path} b/${hunk.path}\n--- a/${hunk.path}\n+++ b/${hunk.path}\n${hunk.patch}\n`,
    [hunk.path, hunk.patch],
  );
  const options = useMemo(
    () => ({ ...codeOptions, diffStyle: "unified" as const, disableFileHeader: true, stickyHeaders: false }),
    [codeOptions],
  );
  return <PatchDiff patch={patch} options={options as any} />;
}
