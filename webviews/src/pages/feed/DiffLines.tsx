// A whole diff's lines in the Inbox detail, mounting only those near the viewport (the visible-only
// rule): an attachment's diff has no length cap, and each line used to be a mounted row keyed by its
// index. The lines window (TanStack Virtual) against the detail pane that scrolls them, from where
// they start in it (scrollMargin); about one viewport each side mounts, in the flow between two blocks
// standing in for the rest. Rows are memoized on their text, so a scroll draws only the lines it
// brings in. Lines are one height (one line each, cut with an ellipsis), so the first one measured
// sizes all the others.
//
// Copy: the browser copies only mounted text, so a selection across lines that are not mounted copies
// what the diff says instead, one line each as the browser copies these rows; select-all, whose end
// lands in the block standing in for the lines below the window, copies the whole diff. The lines a
// selection starts and ends on stay mounted, however it was made (a drag, Shift-click, Shift and the
// arrows), so a scroll keeps both of its ends; no other line a press once touched stays mounted.
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
import { watchPress } from "../../ui/pressRelease";

/** A line's height before the first one is measured (caption text, 14 px lines). */
const LINE_ESTIMATE = 14;
/** At least this many lines above and below the visible ones; else one viewport each side. */
const MIN_OVERSCAN = 10;

/** What a line shows: an empty line holds a space, so it keeps its height. It copies as itself. */
export const shownLine = (line: string) => line || " ";

/** A place in the lines: a line's index and a character in what it shows. */
export interface LinePoint {
  line: number;
  char: number;
}

/** The text of `lines` from `start` to `end` (its char may pass the line's end): the diff's own text,
 *  so an empty line copies as nothing, not the space it shows. A char in an empty line's space is
 *  past its end, and slices nothing. */
export function copiedText(lines: readonly string[], start: LinePoint, end: LinePoint): string {
  const out: string[] = [];
  for (let at = start.line; at <= end.line && at < lines.length; at++)
    out.push(lines[at]!.slice(at === start.line ? start.char : 0, at === end.line ? end.char : undefined));
  return out.join("\n");
}

const NONE: readonly number[] = [];
/** The key of the block below the lines: one element, mounted however far the lines scroll. */
const END = "gap:end";
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
  // selection. A caret is a selection too (a Shift-click extends from it), so a click that puts one
  // keeps its line. A press also keeps its own line until it is released, before the selection says
  // where it now is. Each selection change, press and release sets the pins again from those (at most
  // three lines), never adding to the last ones: a press that leaves no selection end in the lines
  // leaves no line mounted once released.
  const [pinned, setPinned] = useState<readonly number[]>(NONE);
  const pressed = useRef(-1);
  const repin = useCallback(() => {
    const root = body.current;
    const selection = root?.ownerDocument.getSelection();
    const ends = [pressed.current];
    if (selection && selection.rangeCount > 0)
      ends.push(lineOf(root!, selection.anchorNode), lineOf(root!, selection.focusNode));
    const next = ends.filter((at, index) => at >= 0 && ends.indexOf(at) === index).sort((a, b) => a - b);
    setPinned((previous) => (sameLines(previous, next) ? previous : next));
  }, []);
  // A press may end outside the lines (a drag out of them), or where the document never hears its
  // pointerup: released outside the window, or after the window lost focus mid-press. watchPress
  // ends it on each of those too.
  const stopPress = useRef<() => void>(undefined);
  const onPointerDown = (event: PointerEvent) => {
    stopPress.current?.();
    stopPress.current = undefined;
    const root = body.current;
    pressed.current = lineOf(root, event.target as Node);
    if (root && pressed.current >= 0)
      stopPress.current = watchPress(root.ownerDocument, {
        end: () => {
          stopPress.current = undefined;
          pressed.current = -1;
          repin();
        },
      });
    repin();
  };
  useEffect(() => {
    const document = body.current?.ownerDocument;
    if (!document) return;
    document.addEventListener("selectionchange", repin);
    return () => {
      document.removeEventListener("selectionchange", repin);
      stopPress.current?.();
    };
  }, [repin]);

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
  // line. Each is keyed by the line before it, so the top one stays the same element as lines scroll;
  // the bottom one is keyed as the end and stays mounted, at no height once the last line is, so a
  // select-all ending in it keeps its end there through any scroll (a new element, or none, would
  // move that end out, to the last line mounted then).
  const children: ReactNode[] = [];
  let reached = scrollMargin;
  let previous = -1;
  const gap = (height: number, key = `gap:${previous}`) => {
    if (height > 0 || key === END)
      children.push(<span key={key} aria-hidden="true" data-gap={previous + 1} style={{ height }} />);
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
  gap(Math.max(0, virtualizer.getTotalSize() + scrollMargin - reached), END);

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
    // Inside a block standing in for lines: the selection holds them all. Select-all ends here, in
    // the block below the window, in Chromium and WebKit.
    if (edge === "start") return { line: Number(container.dataset.gap), char: 0 };
    const next = (container.nextElementSibling as HTMLElement | null)?.dataset.index;
    return next === undefined ? lastLine() : { line: Number(next) - 1, char: Number.POSITIVE_INFINITY };
  }
  const next = root.childNodes[offset] as HTMLElement | undefined;
  const at = next?.dataset?.index ?? next?.dataset?.gap;
  if (at === undefined) return edge === "start" ? { line: count, char: 0 } : lastLine();
  const line = Number(at);
  return edge === "start" ? { line, char: 0 } : { line: line - 1, char: Number.POSITIVE_INFINITY };
}

/** The selected text before or after the lines, as the browser copies it: read through the
 *  selection (as the chat's copy reads a chip's text, conversation/chipCopy.ts), so text a person
 *  cannot select (a button's label, the poster line, the diff's file name) is left out and a block
 *  keeps its line end, where the range's own text would run them together. Untrimmed, so a selection
 *  that starts or ends on a space copies it. The person's selection is put back as it was. */
function outside(range: Range, root: HTMLElement, side: "before" | "after"): string {
  const document = root.ownerDocument;
  const part = document.createRange();
  if (side === "before") {
    part.setStart(range.startContainer, range.startOffset);
    part.setEndBefore(root);
  } else {
    part.setStartAfter(root);
    part.setEnd(range.endContainer, range.endOffset);
  }
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0 || !selection.anchorNode || !selection.focusNode) return part.toString();
  const { anchorNode, anchorOffset, focusNode, focusOffset } = selection;
  const kept = selection.getRangeAt(0);
  const forward = kept.startContainer === anchorNode && kept.startOffset === anchorOffset;
  try {
    selection.setBaseAndExtent(part.startContainer, part.startOffset, part.endContainer, part.endOffset);
    // Less the line end where it meets the lines (the block it leaves, or the one the lines start):
    // the copy puts one there. WebKit reads a selection that ends just above the lines as that alone.
    const text = selection.toString();
    return side === "before" ? text.replace(/\n$/, "") : text.replace(/^\n/, "");
  } finally {
    // A forward selection gets its own range back (whoever holds it still holds the selection's);
    // a backward one, its anchor and focus.
    if (forward) {
      selection.removeAllRanges();
      selection.addRange(kept);
    } else selection.setBaseAndExtent(anchorNode, anchorOffset, focusNode, focusOffset);
  }
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
