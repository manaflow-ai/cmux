// A revision's change as unified lines, mounting only the lines near the viewport (the visible-only
// rule): a first revision of a long file is every line added, and each one used to be a mounted row.
// The lines window (TanStack Virtual) against the history pane that scrolls them, from where they
// start in it (scrollMargin); about one viewport each side mounts, in the flow between two blocks
// standing in for the rest. Rows are memoized on their line, so a scroll draws only the lines it
// brings in. Lines are one height each (the hunk's dashed rule is drawn over its first line, not
// added to it), so the first one measured sizes all the others.
//
// Copy: the browser copies only mounted text, so a selection across lines that are not mounted copies
// what the model says instead, as the browser would have (sign, text, the no-newline note, one line
// each). The lines a selection starts and ends on stay mounted, however it was made (a drag,
// Shift-click, Shift and the arrows), so a scroll keeps both of its ends.
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
import type { DiffHunk, DiffLine } from "./lineDiff";

/** A line's height before the first one is measured (caption text, 14 px lines). */
const LINE_ESTIMATE = 14;
/** At least this many lines above and below the visible ones; else one viewport each side. */
const MIN_OVERSCAN = 10;

/** One diff's lines, flattened once: which ones open a hunk, and the widest line in characters. */
export interface DiffModel {
  lines: DiffLine[];
  /** 1 where a line opens a hunk after the first. */
  hunkStarts: Uint8Array;
  /** The widest line's characters (a tab counts as 8), so the box scrolls sideways the same at any scroll. */
  widest: number;
}

export function diffModel(hunks: readonly DiffHunk[]): DiffModel {
  const lines: DiffLine[] = [];
  const starts: number[] = [];
  let widest = 0;
  for (const hunk of hunks) {
    if (lines.length) starts.push(lines.length);
    for (const line of hunk) {
      lines.push(line);
      let width = line.text.length;
      for (let at = line.text.indexOf("\t"); at >= 0; at = line.text.indexOf("\t", at + 1)) width += 7;
      if (width > widest) widest = width;
    }
  }
  const hunkStarts = new Uint8Array(lines.length);
  for (const start of starts) hunkStarts[start] = 1;
  return { lines, hunkStarts, widest };
}

const signOf = (line: DiffLine) => (line.type === "add" ? "+" : line.type === "del" ? "-" : " ");

/** What a line copies as: what the browser copies from its row. */
const copiedLine = (line: DiffLine, noNewline: string) => signOf(line) + line.text + (line.noNewline ? noNewline : "");

/** A place in the lines: a line's index and a character in what it copies as. */
export interface DiffPoint {
  line: number;
  char: number;
}

/** The text of `lines` from `start` to `end` (its char may pass the line's end), as the browser copies rows. */
export function copiedText(lines: readonly DiffLine[], noNewline: string, start: DiffPoint, end: DiffPoint): string {
  const out: string[] = [];
  for (let at = start.line; at <= end.line && at < lines.length; at++) {
    const text = copiedLine(lines[at]!, noNewline);
    out.push(text.slice(at === start.line ? start.char : 0, at === end.line ? end.char : undefined));
  }
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

/** The closest element above `node` that scrolls vertically (the box itself scrolls only sideways). */
function scrollParentOf(node: HTMLElement): HTMLElement {
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = at.ownerDocument.defaultView?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  return node;
}

export function DiffLines({ model, noNewline }: { model: DiffModel; noNewline: string }) {
  const { lines, hunkStarts } = model;
  const box = useRef<HTMLDivElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const viewport = useRef<HTMLElement | null>(null);
  const findViewport = useCallback(() => {
    if (!viewport.current && box.current) viewport.current = scrollParentOf(box.current);
    return viewport.current;
  }, []);

  // Where the lines start in the pane's content, and one viewport of lines. They move only when a
  // box between the lines and the pane resizes, never on a scroll.
  const [scrollMargin, setScrollMargin] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(0);
  const measureMargin = useCallback(() => {
    const scroller = findViewport();
    const start = body.current;
    if (!scroller || !start) return;
    const next =
      start.getBoundingClientRect().top -
      scroller.getBoundingClientRect().top +
      scroller.scrollTop -
      scroller.clientTop;
    setScrollMargin((previous) => (previous === next ? previous : next));
    setViewportHeight(scroller.clientHeight);
  }, [findViewport]);
  useLayoutEffect(() => {
    measureMargin();
    const scroller = findViewport();
    if (!scroller || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureMargin);
    for (let node: HTMLElement | null = box.current; node; node = node.parentElement) {
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

  const items = virtualizer.getVirtualItems();

  // A copy whose selection crosses lines that are not mounted reads them from the model.
  useEffect(() => {
    const document = box.current?.ownerDocument;
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
      parts.push(copiedText(lines, noNewline, start, end));
      if (!root.contains(range.endContainer)) parts.push(outside(range, root, "after"));
      event.clipboardData?.setData("text/plain", parts.filter(Boolean).join("\n"));
      event.preventDefault();
    };
    document.addEventListener("copy", onCopy);
    return () => document.removeEventListener("copy", onCopy);
  }, [lines, noNewline, virtualizer]);

  // A block of the lines' height stands in for each run of lines not mounted: `data-gap` is its first
  // line. Each is keyed by the line before it, so the top one stays the same element as lines scroll.
  const children: ReactNode[] = [];
  let reached = scrollMargin;
  let previous = -1;
  const gap = (height: number) => {
    if (height > 0)
      children.push(<div key={`gap:${previous}`} aria-hidden="true" data-gap={previous + 1} style={{ height }} />);
  };
  for (const { index, start, end } of items) {
    gap(start - reached);
    reached = end;
    previous = index;
    children.push(
      <DiffRow
        key={index}
        index={index}
        line={lines[index]!}
        hunkStart={hunkStarts[index] === 1}
        count={lines.length}
        noNewline={noNewline}
        measure={measure}
      />,
    );
  }
  gap(virtualizer.getTotalSize() + scrollMargin - reached);

  return (
    <div ref={box} className="artifacts-diff" onPointerDown={onPointerDown}>
      {/* Not an ol: the blocks standing in for unmounted lines sit between the rows, and an li's copy
          text differs by engine. */}
      <div
        ref={body}
        className="artifacts-diff-lines"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="list"
        style={{ minWidth: `calc(${model.widest + 2}ch + 2 * var(--ds-space-2))` }}
      >
        {children}
      </div>
    </div>
  );
}

/** Where a selection's boundary falls in the lines; undefined when it cannot say. */
function pointOf(
  root: HTMLElement,
  node: Node,
  offset: number,
  edge: "start" | "end",
  count: number,
): DiffPoint | undefined {
  if (count === 0) return undefined;
  const lastLine = () => ({ line: count - 1, char: Number.POSITIVE_INFINITY });
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

/** The selected text before or after the lines, as the browser's range reads it: untrimmed, so a
 *  selection that starts or ends on a space copies it. */
function outside(range: Range, root: HTMLElement, side: "before" | "after"): string {
  const part = root.ownerDocument.createRange();
  if (side === "before") {
    part.setStart(range.startContainer, range.startOffset);
    part.setEndBefore(root);
  } else {
    part.setStartAfter(root);
    part.setEnd(range.endContainer, range.endOffset);
  }
  return part.toString();
}

interface RowProps {
  index: number;
  line: DiffLine;
  hunkStart: boolean;
  /** Every line's count: a screen reader says where in the change a line is, mounted or not. */
  count: number;
  noNewline: string;
  measure: (node: HTMLElement | null) => void;
}

const DiffRow = memo(function DiffRow({ index, line, hunkStart, count, noNewline, measure }: RowProps) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-line=""
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={count}
      className={`artifacts-line is-${line.type}${hunkStart ? " is-hunk-start" : ""}`}
    >
      <span className="artifacts-sign" aria-hidden="true">
        {signOf(line)}
      </span>
      {line.text}
      {line.noNewline ? <span className="artifacts-no-newline">{noNewline}</span> : null}
    </div>
  );
});
