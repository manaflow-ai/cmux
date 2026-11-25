import { useSyncExternalStore } from "react";
import { selectionText } from "./chipCopy";

export type SelectionReplyLook = "chip" | "icon" | "none" | "row";
const LOOKS: readonly SelectionReplyLook[] = ["chip", "icon", "none", "row"];
let look: SelectionReplyLook = "chip";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the chip.
export function configureSelectionReply(value: unknown): void {
  const next = LOOKS.find((one) => one === value) ?? "chip";
  if (next === look) return;
  look = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => look;
export const useSelectionReplyLook = () => useSyncExternalStore(subscribe, current, current);

/// `text` as a Markdown quote with a blank line after it, as the right-click menu's Quote in Reply
/// makes it (AgentPaneContextMenu.swift `quote`).
export function quoteMarkdown(text: string): string {
  return `${text
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n")}\n\n`;
}

/// Where a quote goes: the pane's Quote in Reply (App.tsx), set while the pane is mounted.
let sink: ((markdown: string) => void) | undefined;
export function setQuoteReplySink(next: ((markdown: string) => void) | undefined): () => void {
  sink = next;
  return () => {
    if (sink === next) sink = undefined;
  };
}
export function quoteInReply(text: string): boolean {
  if (!sink || !text.trim()) return false;
  sink(quoteMarkdown(text));
  return true;
}

const EDITABLE = '[contenteditable]:not([contenteditable="false"]), textarea, input';
/// Text selected here is never offered the chip: the composer and fields, code blocks (selected to
/// copy; their own Copy is in the corner), a guest's read-only transcript and the chip itself.
const EXCLUDED = `${EDITABLE}, .cv-codeblock, pre, [data-read-only-transcript], .cv-selection-reply`;

const elementOf = (node: Node | null): Element | null =>
  node ? (node.nodeType === 1 ? (node as Element) : node.parentElement) : null;

export type SelectionReplyTarget = {
  text: string;
  /** Where the pointer let go (the end, or the start of a backward drag), at its nearest selected
   *  character: the chip centres over it. */
  left: number;
  top: number;
  bottom: number;
  /** The selection's last line: the right of its last character and that line's box. */
  end?: { right: number; top: number; bottom: number };
  /** The selection's first line: the chip may go over it (above the whole selection). */
  start?: { top: number; bottom: number };
  /** The text column the end sits in: where its lines start (the end's block) and its right edge. */
  column?: { left: number; right: number };
};

/// The blocks a transcript line wraps in: where the line under the selection's end starts.
const BLOCK = "p, li, h1, h2, h3, h4, h5, h6, td, th, dd, dt, figcaption, blockquote, .cv-md, [data-row-id]";

/// The box of the column `node` sits in: its block's left (where its lines start) and the
/// message body's right edge. Undefined where there is no layout (a box of no width).
function columnOf(node: Node | null): SelectionReplyTarget["column"] {
  const element = elementOf(node);
  const block = element?.closest(BLOCK)?.getBoundingClientRect?.();
  const body = element?.closest(".cv-md, [data-row-id]")?.getBoundingClientRect?.();
  if (!block?.width || !body?.width) return undefined;
  return { left: block.left, right: body.right };
}

/// The text node of the selection's last selected character (its first for a backward drag). A
/// drag let go deep past a block ends the range in the next block, or the next message: its column
/// is not the selected text's. Walks from that end only, a few nodes, never the whole selection.
function edgeTextOf(range: Range, backward: boolean): Node {
  const container = backward ? range.startContainer : range.endContainer;
  const offset = backward ? range.startOffset : range.endOffset;
  const doc = container.ownerDocument;
  if (!doc) return container;
  const walker = doc.createTreeWalker(range.commonAncestorContainer, 4);
  let node: Node | null = container.nodeType === 3 ? container : (container.childNodes[offset] ?? null);
  if (!node) {
    // Past the container's last child: its deepest last descendant.
    node = container;
    while (node.lastChild) node = node.lastChild;
  }
  walker.currentNode = node;
  for (let at: Node | null = node; at; at = backward ? walker.nextNode() : walker.previousNode()) {
    if (at.nodeType !== 3 || !(at as Text).data.trim() || !range.intersectsNode(at)) continue;
    // The boundary's own text node holds no selected character when the range stops at its edge.
    if (at === container && offset === (backward ? (at as Text).length : 0)) continue;
    return at;
  }
  return container;
}

/// The selected transcript text and where its end is (viewport px), or undefined when the
/// selection is collapsed, blank, or not wholly in transcript messages.
export function selectionReplyTarget(doc: Document): SelectionReplyTarget | undefined {
  const selection = doc.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return undefined;
  for (const node of [selection.anchorNode, selection.focusNode]) {
    const element = elementOf(node);
    if (!element?.closest("[data-row-id]") || element.closest(EXCLUDED)) return undefined;
  }
  // A cmux link chip quotes as its link (chipCopy.ts).
  const text = selectionText(selection).trim();
  if (!text) return undefined;
  const range = selection.getRangeAt(0);
  const rects = Array.from(range.getClientRects?.() ?? []).filter((rect) => rect.width || rect.height);
  // A selection that runs to the start of the next block ends in a caret-thin box there: its last
  // character is the last box with a width.
  const wide = rects.filter((rect) => rect.width > 0);
  const last = (wide.length ? wide : rects)[(wide.length ? wide : rects).length - 1];
  // A backward drag ends at the range's start: the chip goes where the pointer let go.
  const backward =
    selection.anchorNode !== null &&
    selection.focusNode !== null &&
    (selection.anchorNode === selection.focusNode
      ? selection.focusOffset < selection.anchorOffset
      : Boolean(selection.anchorNode.compareDocumentPosition(selection.focusNode) & 2));
  // A drag let go deep in the blank space past a block (or before one, backward) leaves that
  // caret-thin box where the pointer is not: the chip goes on the first or last selected character.
  // Leo, 2026-11-11: "if you go close, you still get it. But if you go deep into it, there's
  // something that messes up there."
  const rect = (backward ? (wide[0] ?? rects[0]) : last) ?? range.getBoundingClientRect?.();
  if (!rect) return { text, left: 0, top: 0, bottom: 0 };
  const end = last ? { right: last.right, top: last.top, bottom: last.bottom } : undefined;
  return {
    text,
    left: backward ? rect.left : rect.right,
    top: rect.top,
    bottom: rect.bottom,
    end,
    start: wide[0] ? { top: wide[0].top, bottom: wide[0].bottom } : undefined,
    column: columnOf(edgeTextOf(range, backward)),
  };
}

export type PlaceRect = { left: number; top: number; right: number; bottom: number };
/// Where the chip goes.
export type SelectionReplyPlace = { left: number; top: number };
const PLACE_GAP = 6;
/// The chip's margin inside the visible transcript's top and bottom.
const EDGE = 2;
/// How many lines past the rows next to the end the chip looks beside the selection for a free spot.
const FARTHER = 3;

/// The transcript's scroller: the first scrolling ancestor of `node` (a handful of elements up from
/// the text), or undefined outside one.
export function transcriptScroller(doc: Document, node: Node | null): Element | undefined {
  const view = doc.defaultView;
  for (let element = elementOf(node); element && element !== doc.body; element = element.parentElement) {
    const overflow = view?.getComputedStyle?.(element).overflowY;
    if (overflow === "auto" || overflow === "scroll") return element;
  }
  return undefined;
}

/// The whole transcript a selection is in: its outer scroller, never a card that scrolls inside one
/// row (an opened agent message), whose rows are not the transcript's.
export function transcriptRoot(doc: Document, node: Node | null): Element | undefined {
  return elementOf(node)?.closest(".acpmux-scroll") ?? transcriptScroller(doc, node);
}

/// The same spot for the same text: placing the chip again would move nothing.
export function sameReplyTarget(a: SelectionReplyTarget, b: SelectionReplyTarget): boolean {
  return (
    a.text === b.text &&
    a.left === b.left &&
    a.top === b.top &&
    a.bottom === b.bottom &&
    a.end?.right === b.end?.right &&
    a.end?.top === b.end?.top &&
    a.end?.bottom === b.end?.bottom &&
    a.start?.top === b.start?.top &&
    a.start?.bottom === b.start?.bottom &&
    a.column?.left === b.column?.left &&
    a.column?.right === b.column?.right
  );
}

/// The part of the viewport where the transcript shows: its scroller's box, above a composer dock
/// floating over it. The chip never leaves it. Read once per placed chip.
export function transcriptClip(doc: Document, node: Node | null): { top: number; bottom: number } {
  const view = doc.defaultView;
  let top = 0;
  let bottom = doc.documentElement.clientHeight || view?.innerHeight || 0;
  const scroller = transcriptScroller(doc, node);
  const box = scroller?.getBoundingClientRect();
  if (box?.height) {
    top = Math.max(top, box.top);
    bottom = Math.min(bottom, box.bottom);
  }
  // A composer dock drawn over the transcript's foot (bottomStack.css `data-dock="float"`).
  const dock = doc.querySelector(".acpmux-dock");
  for (const element of dock ? [dock, ...Array.from(dock.children)] : []) {
    const box = element.getBoundingClientRect();
    if (box.height && box.top > top && box.top < bottom && box.bottom >= bottom - 1) bottom = box.top;
  }
  return { top, bottom };
}

/// What text a spot would cover: the boxes of transcript text, selected or not, that cross `box`
/// (viewport px). The chip covers no words, the selection's own included (user 2026-11-15: it hid
/// the words just selected).
export type TextProbe = (box: PlaceRect) => readonly PlaceRect[];

const crosses = (a: PlaceRect, b: PlaceRect) =>
  Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
  Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;

/// A probe that asks the DOM at each spot: the transcript rows crossing it and the boxes of their
/// text. Nothing is measured ahead, so a spot far from the selection is measured where it is.
export function transcriptTextProbe(doc: Document): TextProbe {
  const part = doc.createRange();
  return (box) => {
    const found: PlaceRect[] = [];
    for (const row of Array.from(doc.querySelectorAll("[data-row-id]"))) {
      if (row.parentElement?.closest("[data-row-id]")) continue;
      const rowBox = row.getBoundingClientRect();
      if (!crosses(box, rowBox)) continue;
      const walker = doc.createTreeWalker(row, 4);
      for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null) {
        if (!node.data.trim()) continue;
        part.selectNodeContents(node);
        for (const rect of Array.from(part.getClientRects?.() ?? []))
          if (rect.width && rect.height && crosses(box, rect)) found.push(rect);
      }
    }
    return found;
  };
}

/// Where the chip goes, or undefined to hide it. Every candidate goes through one `accept`: it
/// slides the chip into its bounds, then takes the spot only when it is inside the visible
/// transcript (`pane`, from its top to its height) and `probe` finds no text under it, the
/// selection's own included. The bounds are the transcript column, or the pane where the column is
/// narrower than the chip (a short prompt in its bubble). A selection whose last line is not in the
/// visible transcript hides the chip until it scrolls back. Leo, 2026-11-05, on the chip drawn over
/// a "Sent to" line: "this is a bad reply"; 2026-11-07: "if it's ever on the right edge, just make
/// it in line"; user 2026-11-15: it covered the words just selected.
/// The candidates, in order:
///   1. Over the selection's end, centred on it (as Claude and ChatGPT do), where that is clear.
///   2. Inline: just after the selection's last character, centred on that line, when it fits
///      before the column's edge and the rest of the line is empty.
///   3. Just under the selection's last line, centred on its end (a paragraph break, a block's end).
///   4. Above the selection's first line or under its last, a line further each step, nearest
///      first, centred on the end where it fits: a paragraph's break, the gap between messages.
///   5. The nearest free spot beside the lines next to the selection (up to three lines out).
/// With none free in view (one long paragraph filling the pane), it hides; the right-click menu's
/// Quote in Reply still quotes the selection.
export function selectionReplyPlace(
  target: SelectionReplyTarget,
  size: { width: number; height: number },
  pane: { width: number; height: number; top?: number },
  probe: TextProbe,
): SelectionReplyPlace | undefined {
  const { width, height } = size;
  const gap = PLACE_GAP;
  const paneLeft = gap;
  const paneRight = pane.width - gap;
  const columnLeft = Math.max(target.column?.left ?? paneLeft, paneLeft);
  const columnRight = Math.min(target.column?.right ?? paneRight, paneRight);
  const narrow = columnRight - columnLeft < width;
  const left = narrow ? paneLeft : columnLeft;
  const right = narrow ? paneRight : columnRight;
  const top = Math.max(pane.top ?? 0, 0);
  const bottom = pane.height > 0 ? pane.height : Infinity;
  const end = target.end ?? { right: target.left, top: target.top, bottom: target.bottom };
  if (end.top < top || end.bottom > bottom) return undefined;
  // The selection's first line: its top bounds the spots over the selection.
  const first = target.start && target.start.top < end.top ? target.start : end;

  /// The one exit: the spot slid into the bounds, if it is in view and over no text.
  const accept = (x: number, y: number): SelectionReplyPlace | undefined => {
    const cx = Math.max(left, Math.min(x, right - width));
    const cy = Math.max(top + EDGE, Math.min(y, bottom - EDGE - height));
    const box = { left: cx, top: cy, right: cx + width, bottom: cy + height };
    if (box.left < left - 0.5 || box.right > right + 0.5 || box.top < top || box.bottom > bottom) return undefined;
    if (probe(box).length > 0) return undefined;
    return { left: cx, top: cy };
  };

  const line = (end.top + end.bottom - height) / 2;
  const under = end.bottom + gap;
  const over = first.top - height - gap;
  const step = Math.max(end.bottom - end.top, height / 2);
  const centred = end.right - width / 2;
  /// Over the first line and under the last, one step further each time, nearest first, while in view.
  function* vertical(): Generator<[number, number]> {
    for (let k = 0; ; k += 1) {
      const up = over - k * step;
      const down = under + k * step;
      const upIn = up >= top + EDGE;
      const downIn = down + height <= bottom - EDGE;
      if (!upIn && !downIn) return;
      if (upIn) yield [centred, up];
      if (downIn) yield [centred, down];
    }
  }
  /// The rows next to the selection out to `FARTHER` lines, each measured once across the bounds:
  /// the spots that start or end at a gap's edge and cross no text there, nearest the end first.
  const beside = (): [number, number][] => {
    const spots: { x: number; y: number; far: number }[] = [];
    for (let k = 0; k <= FARTHER; k += 1)
      for (const y of [over - k * step, under + k * step]) {
        if (y < top || y + height > bottom) continue;
        const band = probe({ left, right, top: y, bottom: y + height });
        const xs = [left, right - width, ...band.flatMap((rect) => [rect.right + gap, rect.left - gap - width])];
        for (const x of xs) {
          const box = { left: x, top: y, right: x + width, bottom: y + height };
          if (x < left || x + width > right || band.some((rect) => crosses(box, rect))) continue;
          spots.push({ x, y, far: Math.abs(x + width / 2 - end.right) + Math.abs(y - line) });
        }
      }
    return spots.sort((a, b) => a.far - b.far).map(({ x, y }) => [x, y]);
  };
  function* candidates(): Generator<[number, number]> {
    yield [target.left - width / 2, target.top - height - gap];
    if (end.right + gap + width <= right) yield [end.right + gap, line];
    yield [centred, under];
    yield* vertical();
    yield* beside();
  }
  for (const [x, y] of candidates()) {
    const place = accept(x, y);
    if (place) return place;
  }
  return undefined;
}
