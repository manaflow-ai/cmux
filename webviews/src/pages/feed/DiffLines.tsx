// A whole diff's lines in the Inbox detail, mounting only those near the viewport (the visible-only
// rule): an attachment's diff has no length cap, and each line used to be a mounted row keyed by its
// index. The lines window (TanStack Virtual) against the detail pane that scrolls them, from where
// they start in it (scrollMargin); about one viewport each side mounts, in the flow between two blocks
// standing in for the rest. Rows are memoized on their text, so a scroll draws only the lines it
// brings in. Lines are one height (one line each, cut with an ellipsis), so the first one measured
// sizes all the others.
//
// Copy: the browser copies only mounted text, so a selection across lines that are not mounted copies
// what the diff says instead, one line each as the browser copies these rows. The lines a selection
// starts and ends on stay mounted, however it was made (a drag, Shift-click, Shift and the arrows),
// so a scroll keeps both of its ends.
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent,
  type ReactNode,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range as VirtualRange } from "@tanstack/react-virtual";

/** A line's height before the first one is measured (caption text, 14 px lines). */
const LINE_ESTIMATE = 14;
/** At least this many lines above and below the visible ones; else one viewport each side. */
const MIN_OVERSCAN = 10;

/** What a line shows and copies as: an empty line holds a space, so it keeps its height. */
export const shownLine = (line: string) => line || " ";

/** A place in the lines: a line's index and a character in what it shows. */
export interface LinePoint {
  line: number;
  char: number;
}

/** The text of `lines` from `start` to `end` (its char may pass the line's end), as the browser copies rows. */
export function copiedText(lines: readonly string[], start: LinePoint, end: LinePoint): string {
  const out: string[] = [];
  for (let at = start.line; at <= end.line && at < lines.length; at++)
    out.push(shownLine(lines[at]!).slice(at === start.line ? start.char : 0, at === end.line ? end.char : undefined));
  return out.join("\n");
}

const NONE: readonly number[] = [];
const sameLines = (a: readonly number[], b: readonly number[]) =>
  a.length === b.length && a.every((at, index) => at === b[index]);

/** The index of the line under `root` that holds `node`, or -1. */
function lineOf(root: HTMLElement | null, node: Node | null): number {
  if (!root || !node || !root.contains(node)) return -1;
  const row = (node.nodeType === 1 ? (node as Element) : node.parentElement)?.closest<HTMLElement>("[data-line]");
  return row && root.contains(row) ? Number(row.dataset.index) : -1;
}

/** The closest element above `node` that scrolls vertically. */
function scrollParentOf(node: HTMLElement): HTMLElement {
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = at.ownerDocument.defaultView?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  return node;
}

export function DiffLines({ lines, tone }: { lines: readonly string[]; tone: (line: string) => string | undefined }) {
  const body = useRef<HTMLDivElement>(null);
  const viewport = useRef<HTMLElement | null>(null);
  const findViewport = useCallback(() => {
    if (!viewport.current && body.current) viewport.current = scrollParentOf(body.current);
    return viewport.current;
  }, []);

  // Where the lines start in the pane's content, and one viewport of lines. They move only when a
  // box between the lines and the pane resizes, never on a scroll.
  const [scrollMargin, setScrollMargin] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(0);
  const measureMargin = useCallback(() => {
    const scroller = findViewport();
    const start = body.current;
    if (!scroller || !start || scroller === start) return;
    const padding = parseFloat(start.ownerDocument.defaultView?.getComputedStyle(start).paddingTop ?? "") || 0;
    const next =
      start.getBoundingClientRect().top -
      scroller.getBoundingClientRect().top +
      scroller.scrollTop -
      scroller.clientTop +
      start.clientTop +
      padding;
    setScrollMargin((previous) => (previous === next ? previous : next));
    setViewportHeight(scroller.clientHeight);
  }, [findViewport]);
  useLayoutEffect(() => {
    measureMargin();
    const scroller = findViewport();
    if (!scroller || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureMargin);
    for (let node: HTMLElement | null = body.current; node; node = node.parentElement) {
      observer.observe(node);
      if (node === scroller) break;
    }
    return () => observer.disconnect();
  }, [findViewport, measureMargin]);

  // The lines a selection starts and ends on stay mounted: removing one would move that end of the
  // selection. Each selection change pins its anchor's and focus's lines, whatever made it; a pointer
  // also pins its line at once, keeping the others until the selection says where it now is (a
  // Shift-click's anchor is a line already pinned, which may be out of view).
  const [pinned, setPinned] = useState<readonly number[]>(NONE);
  const pin = useCallback(
    (next: readonly number[]) => setPinned((previous) => (sameLines(previous, next) ? previous : next)),
    [],
  );
  const onPointerDown = (event: PointerEvent) => {
    const at = lineOf(body.current, event.target as Node);
    if (at >= 0 && !pinned.includes(at)) pin([...pinned, at]);
  };
  useEffect(() => {
    const document = body.current?.ownerDocument;
    if (!document) return;
    const onSelectionChange = () => {
      const selection = document.getSelection();
      if (!selection || selection.rangeCount === 0) return pin(NONE);
      const ends = [lineOf(body.current, selection.anchorNode), lineOf(body.current, selection.focusNode)];
      pin(ends.filter((at, index) => at >= 0 && ends.indexOf(at) === index));
    };
    document.addEventListener("selectionchange", onSelectionChange);
    return () => document.removeEventListener("selectionchange", onSelectionChange);
  }, [pin]);

  // The first measured line sizes every line not yet mounted: they are all one height.
  const lineHeight = useRef(0);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns a mutable instance, so the React Compiler skips this component, as in ui/VirtualList.
  const virtualizer = useVirtualizer({
    count: lines.length,
    getScrollElement: findViewport,
    scrollMargin,
    estimateSize: () => lineHeight.current || LINE_ESTIMATE,
    overscan: Math.max(MIN_OVERSCAN, Math.ceil(viewportHeight / (lineHeight.current || LINE_ESTIMATE))),
    rangeExtractor: (range: VirtualRange) => {
      const indexes = defaultRangeExtractor(range);
      for (const at of pinned)
        if (at < lines.length && !indexes.includes(at)) {
          indexes.push(at);
          indexes.sort((a, b) => a - b);
        }
      return indexes;
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      if (node && !lineHeight.current && node.offsetHeight > 0) lineHeight.current = node.offsetHeight;
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );

  // A copy whose selection crosses lines that are not mounted reads them from the diff.
  useEffect(() => {
    const document = body.current?.ownerDocument;
    if (!document) return;
    const onCopy = (event: ClipboardEvent) => {
      const root = body.current;
      const selection = document.getSelection();
      if (!root || !selection || selection.rangeCount === 0 || selection.isCollapsed) return;
      const range = selection.getRangeAt(0);
      if (!range.intersectsNode(root)) return;
      const start = pointOf(root, range.startContainer, range.startOffset, "start", lines.length);
      const end = pointOf(root, range.endContainer, range.endOffset, "end", lines.length);
      if (!start || !end || end.line < start.line) return;
      let shown = 0;
      for (const { index } of virtualizer.getVirtualItems()) if (index >= start.line && index <= end.line) shown++;
      // Every line it crosses is mounted: the browser copies them as it always has.
      if (shown === end.line - start.line + 1) return;
      const parts: string[] = [];
      if (!root.contains(range.startContainer)) parts.push(outside(range, root, "before"));
      parts.push(copiedText(lines, start, end));
      if (!root.contains(range.endContainer)) parts.push(outside(range, root, "after"));
      event.clipboardData?.setData("text/plain", parts.filter(Boolean).join("\n"));
      event.preventDefault();
    };
    document.addEventListener("copy", onCopy);
    return () => document.removeEventListener("copy", onCopy);
  }, [lines, virtualizer]);

  // A block of the lines' height stands in for each run of lines not mounted: `data-gap` is its first
  // line. Each is keyed by the line before it, so the top one stays the same element as lines scroll.
  const children: ReactNode[] = [];
  let reached = scrollMargin;
  let previous = -1;
  const gap = (height: number) => {
    if (height > 0)
      children.push(<span key={`gap:${previous}`} aria-hidden="true" data-gap={previous + 1} style={{ height }} />);
  };
  for (const { index, start, end } of virtualizer.getVirtualItems()) {
    gap(start - reached);
    reached = end;
    previous = index;
    const line = lines[index]!;
    children.push(
      <DiffRow key={index} index={index} line={line} tone={tone(line)} count={lines.length} measure={measure} />,
    );
  }
  gap(virtualizer.getTotalSize() + scrollMargin - reached);

  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- not a ul: blocks standing in for unmounted lines sit between the rows
    <div ref={body} className="feed-diff-lines" role="list" onPointerDown={onPointerDown}>
      {children}
    </div>
  );
}

/** Where a selection's boundary falls in the lines; undefined when it cannot say. */
function pointOf(root: HTMLElement, node: Node, offset: number, edge: "start" | "end", count: number) {
  if (count === 0) return undefined;
  const lastLine = (): LinePoint => ({ line: count - 1, char: Number.POSITIVE_INFINITY });
  // Outside the lines: the selection starts above them or ends below them.
  if (node !== root && !root.contains(node)) return edge === "start" ? { line: 0, char: 0 } : lastLine();
  const element = node.nodeType === 1 ? (node as Element) : node.parentElement;
  const row = element?.closest<HTMLElement>("[data-line]");
  if (row && root.contains(row)) {
    const before = row.ownerDocument.createRange();
    before.setStart(row, 0);
    before.setEnd(node, offset);
    return { line: Number(row.dataset.index), char: before.toString().length };
  }
  // Between rows: at the child `offset` points to (a row, or a block standing in for lines).
  const container = node === root ? root : (element?.closest<HTMLElement>("[data-gap]") ?? undefined);
  if (!container) return undefined;
  if (container !== root) {
    const from = Number(container.dataset.gap);
    return edge === "start" ? { line: from, char: 0 } : { line: Math.max(0, from - 1), char: Number.POSITIVE_INFINITY };
  }
  const next = root.childNodes[offset] as HTMLElement | undefined;
  const at = next?.dataset?.index ?? next?.dataset?.gap;
  if (at === undefined) return edge === "start" ? { line: count, char: 0 } : lastLine();
  const line = Number(at);
  return edge === "start" ? { line, char: 0 } : { line: line - 1, char: Number.POSITIVE_INFINITY };
}

/** The selected text before or after the lines, as the browser's range reads it. */
function outside(range: Range, root: HTMLElement, side: "before" | "after"): string {
  const part = root.ownerDocument.createRange();
  if (side === "before") {
    part.setStart(range.startContainer, range.startOffset);
    part.setEndBefore(root);
  } else {
    part.setStartAfter(root);
    part.setEnd(range.endContainer, range.endOffset);
  }
  return part.toString().trim();
}

interface RowProps {
  index: number;
  line: string;
  tone: string | undefined;
  /** Every line's count: a screen reader says where in the diff a line is, mounted or not. */
  count: number;
  measure: (node: HTMLElement | null) => void;
}

const DiffRow = memo(function DiffRow({ index, line, tone, count, measure }: RowProps) {
  return (
    <span
      ref={measure}
      data-index={index}
      data-line=""
      className="feed-diff-line"
      data-tone={tone}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={count}
    >
      {shownLine(line)}
    </span>
  );
});
