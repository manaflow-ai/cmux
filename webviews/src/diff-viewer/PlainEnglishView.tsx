// Plain English: the diff read as sentences. Each hunk is one row, the sentence an agent wrote
// for it (hunkSummaries.ts), with its code folded beneath; a click unfolds the code. Rows only
// ask for a sentence while they are on screen or within a screen of it (one
// IntersectionObserver), so a 40-file change costs the hunks you look at.
//
// A row's height is fixed before its sentence comes: while it loads the row shows the hunk's
// first changed line in the same box, and the sentence slides in over it, so nothing above or
// below moves and the scroll position stays put. Reduce Motion fades it in without the slide.
import { PatchDiff } from "@pierre/diffs/react";
import { memo, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Icon } from "../icons";
import type { DiffViewerLabelResolver } from "../labels";
import { type HunkRef, hunkRefs, type SummaryFileDiff, type SummaryState, type SummaryStore } from "./hunkSummaries";

/** How far past the window a row still asks: one screen above and below. */
const NEAR = "100% 0px 100% 0px";

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

export function PlainEnglishView({ files, store, label, codeOptions, onOpenInDiff }: PlainEnglishViewProps) {
  const sections = useMemo(
    () => files.map((file) => ({ file, refs: hunkRefs(file.itemId, file.fileDiff) })).filter((s) => s.refs.length > 0),
    [files],
  );
  const order = useMemo(() => sections.flatMap((section) => section.refs), [sections]);
  const scroller = useRef<HTMLDivElement | null>(null);
  const observe = useNearWindow(scroller, order, store);
  return (
    <div className="plain-english" ref={scroller} aria-label={label("plainEnglish")}>
      <p className="plain-english-note">{label("hunkSummaryNote")}</p>
      {sections.map(({ file, refs }) => (
        <section key={file.itemId} className="plain-english-file">
          <h3 className="plain-english-path" title={refs[0]?.path}>
            {refs[0]?.path}
          </h3>
          <ol className="plain-english-hunks">
            {refs.map((ref) => (
              <HunkSentence
                key={ref.id}
                hunk={ref}
                store={store}
                label={label}
                observe={observe}
                codeOptions={codeOptions}
                onOpenInDiff={onOpenInDiff}
              />
            ))}
          </ol>
        </section>
      ))}
    </div>
  );
}

/**
 * One IntersectionObserver over the view's rows: the hunks in or within a screen of the window,
 * in reading order, become the store's queue each frame they change. Disconnects on unmount.
 */
function useNearWindow(
  scroller: React.RefObject<HTMLDivElement | null>,
  order: readonly HunkRef[],
  store: SummaryStore,
): (element: HTMLElement | null, id: string) => void {
  const near = useRef(new Set<string>());
  const elements = useRef(new Map<string, HTMLElement>());
  const orderRef = useRef(order);
  orderRef.current = order;
  const frame = useRef(0);
  const observer = useRef<IntersectionObserver | null>(null);
  const publish = useCallback(() => {
    if (frame.current) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = 0;
      store.want(orderRef.current.filter((ref) => near.current.has(ref.id)));
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
  useEffect(() => publish(), [order, publish]);
  return useCallback((element: HTMLElement | null, id: string) => {
    const previous = elements.current.get(id);
    if (previous && previous !== element) {
      observer.current?.unobserve(previous);
      elements.current.delete(id);
      near.current.delete(id);
    }
    if (element) {
      elements.current.set(id, element);
      observer.current?.observe(element);
    }
  }, []);
}

function useSummary(store: SummaryStore, key: string): SummaryState {
  const subscribe = useCallback((listener: () => void) => store.subscribe(key, listener), [store, key]);
  const read = useCallback(() => store.get(key), [store, key]);
  return useSyncExternalStore(subscribe, read, read);
}

const HunkSentence = memo(function HunkSentence({
  hunk,
  store,
  label,
  observe,
  codeOptions,
  onOpenInDiff,
}: {
  hunk: HunkRef;
  store: SummaryStore;
  label: DiffViewerLabelResolver;
  observe: (element: HTMLElement | null, id: string) => void;
  codeOptions?: Record<string, unknown>;
  onOpenInDiff?: (ref: HunkRef) => void;
}) {
  const state = useSummary(store, hunk.key);
  const [open, setOpen] = useState(false);
  // A sentence already known when the row mounts is drawn in place; one that comes while the row
  // shows slides in.
  const [arrives] = useState(() => state.kind === "loading");
  const ref = useCallback((element: HTMLLIElement | null) => observe(element, hunk.id), [observe, hunk.id]);
  const codeId = `${hunk.id}-code`;
  return (
    <li className="plain-english-hunk" data-hunk-id={hunk.id} ref={ref}>
      <button
        type="button"
        className="plain-english-row"
        data-state={state.kind}
        data-arrives={arrives || undefined}
        aria-expanded={open}
        aria-controls={open ? codeId : undefined}
        aria-busy={state.kind === "loading" || undefined}
        onClick={() => setOpen((shown) => !shown)}
      >
        <Icon name={open ? "chevronDown" : "chevronRight"} />
        <span className="plain-english-text">
          {/* Both sit in one grid cell: the sentence takes the preview's place, never its height. */}
          <code className="plain-english-preview" aria-hidden={state.kind === "ready" || undefined}>
            {hunk.preview}
          </code>
          {state.kind === "ready" ? (
            <span className="plain-english-sentence" title={state.text}>
              {state.text}
            </span>
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
