// The lines a long block draws inside its own fixed-height box (a Shell block's output, a call's
// output, a read's lines; BlockParts.tsx `Lines`, StreamingCode.tsx `PlainCodeLines`): the box is
// eight lines tall however long the text is (blockPartsModel.ts `PREVIEW_LINES`), so only the lines
// in its viewport and one box height past each edge are mounted, whole chunks of `WINDOW_CHUNK`.
// Two empty spacers stand for the rest. Leo 2026-11-18: "we draw the visible area, right?"
//
// The box's own height never changes, so the transcript row around it does not move. Inside the
// box the spacers are an estimate (the mounted lines' average height, exact for code and unwrapped
// output; a wrapped line may take more rows): when the window moves, the line the reader is on is
// held where it was, so a wrong estimate moves the box's scrollbar, never its text. Per scroll
// event it reads three rects; it never walks the text.
//
// A selection that touches the block keeps every line between its ends mounted for as long as it
// is held, so a drag across lines (and Select All) copies what the page would have copied whole.
// Find in Chat opens a block it reveals whole (blockPartsModel.ts `usePreview` "all"), where the
// caller turns the window off: its counts and highlights read every line, as before.
import { useCallback, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { PREVIEW_LINES } from "./blockPartsModel";

/// Lines mounted and dropped together: one box of them.
export const WINDOW_CHUNK = PREVIEW_LINES;
/// Box heights mounted past each edge of the viewport.
export const WINDOW_OVERSCAN = 1;
/// A block with no more lines than this draws whole: the window would mount most of it anyway.
export const WINDOW_FROM = 4 * WINDOW_CHUNK;
/// On the box while its lines are windowed: its spacers change size, so the browser's own scroll
/// anchoring stays off there (conversation.css) and this module holds the reader's line instead.
export const LINE_WINDOW_ATTRIBUTE = "data-line-window";

export type LineWindow = {
  /** The first line mounted, and the one after the last. */
  from: number;
  to: number;
  /** The spacers' heights, in px. */
  before: number;
  after: number;
  /** For the empty elements just before the first mounted line and just after the last, siblings
   * of the lines. */
  top: (node: HTMLElement | null) => void;
  bottom: (node: HTMLElement | null) => void;
};

/// `armed` once a measure has set the range: a box that starts windowing while scrolled (a command
/// that finished with its box at the end) draws whole for that one commit, so the first measure reads
/// the lines it holds.
type Range = { from: number; to: number; line: number; armed: boolean };

const chunkFloor = (line: number) => Math.max(0, Math.floor(line / WINDOW_CHUNK) * WINDOW_CHUNK);
const chunkCeil = (line: number, total: number) => Math.min(total, Math.ceil(line / WINDOW_CHUNK) * WINDOW_CHUNK);

/// The lines of `total` to mount while `box` scrolls them, when `enabled` (with more than
/// `WINDOW_FROM` lines); off, every line. Call it in the component that renders `box` (its ref is
/// set by the time that component's layout effects run), and hand the window to the lines.
export function useLineWindow(box: RefObject<HTMLElement | null>, total: number, enabled: boolean): LineWindow {
  const on = enabled && total > WINDOW_FROM;
  const [range, setRange] = useState<Range>(() => ({
    from: 0,
    to: Math.min(total, 2 * WINDOW_CHUNK),
    line: 0,
    armed: on,
  }));
  const windowed = on && range.armed;
  const from = windowed ? Math.min(range.from, chunkFloor(total)) : 0;
  const to = windowed ? Math.min(Math.max(range.to, from), total) : total;
  const before = windowed ? from * range.line : 0;
  const after = windowed ? (total - to) * range.line : 0;
  const topNode = useRef<HTMLElement | null>(null);
  const bottomNode = useRef<HTMLElement | null>(null);
  // What the last commit drew, the selection's lines, and the line to hold through the next commit.
  const drawn = useRef({ from, to, total, base: 0, line: range.line, windowed });
  const pin = useRef<{ from: number; to: number } | null>(null);
  const hold = useRef<{ line: number; offset: number } | null>(null);

  const top = useCallback((node: HTMLElement | null) => {
    topNode.current = node;
  }, []);
  const bottom = useCallback((node: HTMLElement | null) => {
    bottomNode.current = node;
  }, []);

  // The mounted line `line`: the host holds the top spacer (at `base`, after a cut mark), the lines,
  // then the bottom spacer.
  const lineNode = (line: number): Element | undefined => {
    const shown = drawn.current;
    if (line < shown.from || line >= shown.to) return undefined;
    return topNode.current?.parentElement?.children[shown.base + 1 + line - shown.from];
  };

  const measure = useCallback(() => {
    const scroller = box.current;
    const head = topNode.current;
    const tail = bottomNode.current;
    if (!scroller || !head || !tail) return;
    const shown = drawn.current;
    const view = scroller.getBoundingClientRect();
    const above = head.getBoundingClientRect();
    const below = tail.getBoundingClientRect();
    const mounted = shown.to - shown.from;
    const lines = below.top - above.bottom;
    const fallback = parseFloat(scroller.ownerDocument.defaultView?.getComputedStyle(scroller).lineHeight ?? "") || 18;
    const line = mounted > 0 && lines > 0 ? lines / mounted : shown.line || fallback;
    // The line at the box's top edge, read off what is drawn: through a spacer in proportion to
    // its height, so a stale estimate maps back onto the lines it stood for.
    const y = view.top - above.top;
    const at =
      y < above.height
        ? above.height > 0
          ? (y / above.height) * shown.from
          : shown.from
        : y < above.height + lines
          ? shown.from + (y - above.height) / (lines / Math.max(1, mounted))
          : shown.to + (below.height > 0 ? ((y - above.height - lines) / below.height) * (shown.total - shown.to) : 0);
    const visible = Math.max(1, (scroller.clientHeight || line * WINDOW_CHUNK) / line);
    let next = {
      from: chunkFloor(at - visible * WINDOW_OVERSCAN),
      to: chunkCeil(at + visible * (1 + WINDOW_OVERSCAN), shown.total),
    };
    const held = pin.current;
    if (held)
      next = {
        from: Math.min(next.from, chunkFloor(held.from)),
        to: Math.max(next.to, chunkCeil(held.to, shown.total)),
      };
    if (shown.windowed && next.from === shown.from && next.to === shown.to && Math.abs(line - shown.line) < 0.01)
      return;
    // Hold the line at the top edge when it is drawn; a jump into a spacer has none to hold.
    const anchor = Math.floor(at);
    const node = lineNode(anchor);
    hold.current = node ? { line: anchor, offset: node.getBoundingClientRect().top - view.top } : null;
    setRange({ ...next, line, armed: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `lineNode` reads only refs.
  }, [box]);

  useLayoutEffect(() => {
    const host = topNode.current?.parentElement;
    const base = host && topNode.current ? Array.prototype.indexOf.call(host.children, topNode.current) : 0;
    drawn.current = { from, to, total, base: Math.max(0, base), line: range.line, windowed };
    const held = hold.current;
    hold.current = null;
    const scroller = box.current;
    if (!windowed || !held || !scroller) return;
    const node = lineNode(held.line);
    if (!node) return;
    const moved = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top - held.offset;
    if (Math.abs(moved) >= 0.5) scroller.scrollTop += moved;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [from, to, total, range.line, windowed, box]);

  useLayoutEffect(() => {
    const scroller = box.current;
    if (!on || !scroller) return;
    scroller.setAttribute(LINE_WINDOW_ATTRIBUTE, "");
    const doc = scroller.ownerDocument;
    const onSelection = () => {
      const host = topNode.current?.parentElement;
      const selection = doc.getSelection();
      const selected =
        host && selection && selection.rangeCount > 0 && !selection.isCollapsed ? selection.getRangeAt(0) : null;
      const was = pin.current;
      if (!host || !selected || !selected.intersectsNode(host)) {
        pin.current = null;
        if (was) measure();
        return;
      }
      const shown = drawn.current;
      // The line `node` is in: the host's child that holds it, a spacer standing for its edge.
      const lineOf = (node: Node, edge: number) => {
        let child: Node | null = node;
        while (child && child.parentNode !== host) child = child.parentNode;
        if (!child) return edge;
        if (child === topNode.current) return shown.from;
        if (child === bottomNode.current) return shown.to;
        const index = Array.prototype.indexOf.call(host.children, child) - shown.base - 1;
        // A cut mark before the top spacer stands for the block's start.
        return index < 0 ? 0 : shown.from + index;
      };
      const start = host.contains(selected.startContainer) ? lineOf(selected.startContainer, 0) : 0;
      const end = host.contains(selected.endContainer) ? lineOf(selected.endContainer, shown.total) + 1 : shown.total;
      pin.current = { from: start, to: Math.min(shown.total, end) };
      if (!was || was.from !== pin.current.from || was.to !== pin.current.to) measure();
    };
    measure();
    scroller.addEventListener("scroll", measure, { passive: true });
    doc.addEventListener("selectionchange", onSelection);
    const view = doc.defaultView;
    const resize = view?.ResizeObserver ? new view.ResizeObserver(measure) : undefined;
    resize?.observe(scroller);
    return () => {
      // Off (Find opened the block whole, its command ran again): the next time it windows, it
      // measures what it then draws first.
      setRange((last) => (last.armed ? { ...last, armed: false } : last));
      scroller.removeAttribute(LINE_WINDOW_ATTRIBUTE);
      scroller.removeEventListener("scroll", measure);
      doc.removeEventListener("selectionchange", onSelection);
      resize?.disconnect();
    };
  }, [box, on, measure]);

  return useMemo(() => ({ from, to, before, after, top, bottom }), [from, to, before, after, top, bottom]);
}
