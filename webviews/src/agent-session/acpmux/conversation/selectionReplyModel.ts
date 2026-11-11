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
  /** The selection's last glyph (viewport px): its last non-blank character with a box. The chip
   *  sits just after it, on its line, whichever way the selection was dragged. */
  end: { left: number; right: number; top: number; bottom: number };
  /** The text column that glyph sits in: where its block's lines start and the message body's right edge. */
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

/// The selection's last glyph: the box of its last non-blank character that has one, and the text
/// node it is in. Not the range's last client rect: a range's rects follow the DOM, not the lines, so
/// its last one can be a whole inline element's box (code, a link, bold) or a caret-thin box on the
/// line after (a selection that runs to the next block's start, or ends on a wrap's space). Leo,
/// 2026-11-11, on the chip at the far end of the next line: "if you go deep into it, there's
/// something that messes up there."
/// It walks back from the range's end and stops at the first character with a box, so a long
/// selection (Select All) costs no more than a short one: it runs again on every scroll while shown.
export function lastGlyph(doc: Document, range: Range): { rect: DOMRect; node: Text } | undefined {
  const common = range.commonAncestorContainer;
  const root = common.nodeType === 3 ? (common.parentNode ?? common) : common;
  const walker = doc.createTreeWalker(root, 4);
  // The last text node at or before the range's end.
  const end = range.endContainer;
  let node: Node | null;
  if (end.nodeType === 3) node = end;
  else {
    const after = end.childNodes[range.endOffset];
    let last: Node = end;
    if (!after) while (last.lastChild) last = last.lastChild;
    if (!after && last.nodeType === 3) node = last;
    else {
      walker.currentNode = after ?? last;
      node = walker.previousNode();
    }
  }
  const one = doc.createRange();
  for (; node && range.intersectsNode(node); node = walker.previousNode()) {
    walker.currentNode = node;
    const text = node as Text;
    const from = text === range.startContainer ? range.startOffset : 0;
    const to = text === range.endContainer ? Math.min(range.endOffset, text.length) : text.length;
    for (let at = to - 1; at >= from; at -= 1) {
      if (/\s/.test(text.data[at]!)) continue;
      // The low half of a surrogate pair: its glyph starts one code unit earlier.
      const start = at > from && /[\uDC00-\uDFFF]/.test(text.data[at]!) ? at - 1 : at;
      one.setStart(text, start);
      one.setEnd(text, at + 1);
      const rects = Array.from(one.getClientRects?.() ?? []).filter((rect) => rect.width > 0 && rect.height > 0);
      const rect = rects[rects.length - 1];
      if (rect) return { rect, node: text };
      at = start;
    }
  }
  return undefined;
}

/// The selected transcript text and its last glyph's box (viewport px), or undefined when the
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
  const glyph = lastGlyph(doc, range);
  // No glyph with a box (no layout): the range's own box, else nothing to place by.
  const rect = glyph?.rect ?? range.getBoundingClientRect?.();
  const end = rect
    ? { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom }
    : { left: 0, right: 0, top: 0, bottom: 0 };
  return { text, end, column: columnOf(glyph?.node ?? range.endContainer) };
}

/// Where the chip goes, in viewport px.
export type SelectionReplyPlace = { left: number; top: number };
/// The chip's gap from the selection's last glyph, and from a line it goes over or under.
const PLACE_GAP = 6;
/// Where the chip first tries to go (selectionReplyAnchor): just after the last glyph on its line
/// (the default), over the last glyph, or under its line.
export type SelectionReplyAnchor = "after" | "over" | "under";
/// The chip's margin inside the visible transcript's top and bottom.
const EDGE = 2;

/// The part of the viewport where the transcript shows: its scroller's box, above a composer dock
/// floating over it. The chip never leaves it. Read once per placed chip.
export function transcriptClip(doc: Document, node: Node | null): { top: number; bottom: number } {
  const view = doc.defaultView;
  let top = 0;
  let bottom = doc.documentElement.clientHeight || view?.innerHeight || 0;
  // The first scrolling ancestor (a handful of elements up from the text).
  for (let element = elementOf(node); element && element !== doc.body; element = element.parentElement) {
    const overflow = view?.getComputedStyle?.(element).overflowY;
    if (overflow !== "auto" && overflow !== "scroll") continue;
    const box = element.getBoundingClientRect();
    if (box.height) {
      top = Math.max(top, box.top);
      bottom = Math.min(bottom, box.bottom);
    }
    break;
  }
  // A composer dock drawn over the transcript's foot (bottomStack.css `data-dock="float"`).
  const dock = doc.querySelector(".acpmux-dock");
  for (const element of dock ? [dock, ...Array.from(dock.children)] : []) {
    const box = element.getBoundingClientRect();
    if (box.height && box.top > top && box.top < bottom && box.bottom >= bottom - 1) bottom = box.top;
  }
  return { top, bottom };
}

/// Where the chip goes, or undefined to hide it (the selection's last line is out of the visible
/// transcript). The bounds are the transcript column, or the pane where the column is narrower than
/// the chip (a short prompt in its bubble); the chip stays inside them and inside the visible
/// transcript (`pane`, from its top to its height).
/// Leo, 2026-11-11, on the chip drawn at the right end of the next line for a selection that ended
/// mid-line: "this reply is in the wrong spot". It sits on the selection's own last line, so it never
/// covers a line over or under it (2026-11-05, on the chip over a "Sent to" line: "this is a bad
/// reply"), and never floats off to the side (2026-11-07: "if it's ever on the right edge, just make
/// it in line"). In order:
///   1. Just after the last glyph, centred on its line, when it fits before the bounds' right edge.
///   2. Flipped left: over the selection's own last words, its right edge at the last glyph's.
///   3. Under the last line, centred on the last glyph; over it where the visible transcript ends there.
/// The `over` and `under` anchors (gallery comparison) try their spot first, then the same order.
export function selectionReplyPlace(
  target: SelectionReplyTarget,
  size: { width: number; height: number },
  pane: { width: number; height: number; top?: number },
  anchor: SelectionReplyAnchor = "after",
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
  const { end } = target;
  if (end.top < top || end.bottom > bottom) return undefined;

  const fits = (x: number) => x >= left - 0.5 && x + width <= right + 0.5;
  const slide = (x: number) => Math.max(left, Math.min(x, right - width));
  const inView = (y: number) => y >= top + EDGE && y + height <= bottom - EDGE;
  // Centred on the last line, kept a margin inside the visible transcript.
  const line = Math.max(top + EDGE, Math.min((end.top + end.bottom - height) / 2, bottom - EDGE - height));
  const centred = slide(end.right - width / 2);
  const under = end.bottom + gap;
  const over = end.top - gap - height;

  if (anchor === "over" && inView(over)) return { left: centred, top: over };
  if (anchor === "under" && inView(under)) return { left: centred, top: under };
  const after = end.right + gap;
  if (fits(after)) return { left: after, top: line };
  const own = end.right - width;
  if (fits(own)) return { left: own, top: line };
  if (inView(under)) return { left: centred, top: under };
  if (inView(over)) return { left: centred, top: over };
  return { left: centred, top: line };
}
