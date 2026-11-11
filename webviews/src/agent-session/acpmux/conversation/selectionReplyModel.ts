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

/// The selection bar's other actions (#40948): Copy, Ask in side chat and Add to chat, each the
/// pane's own path (App.tsx): the app's pasteboard, `/side`'s fork with the quote as its prompt,
/// and the right-click menu's Attach selection as context. Set while the pane is mounted.
export type SelectionActionSinks = {
  copy?: (text: string) => void;
  askInSideChat?: (text: string) => void;
  addToChat?: (text: string) => void;
};
let actionSinks: SelectionActionSinks = {};
export function setSelectionActionSinks(next: SelectionActionSinks): () => void {
  actionSinks = next;
  return () => {
    if (actionSinks === next) actionSinks = {};
  };
}
/// Runs the bar's `action` on `text`; false when the pane has no such path or the text is blank.
export function runSelectionAction(action: keyof SelectionActionSinks, text: string): boolean {
  const run = actionSinks[action];
  if (!run || !text.trim()) return false;
  run(text);
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
  /** Where the pointer let go (the end, or the start of a backward drag): the chip centres over it. */
  left: number;
  top: number;
  bottom: number;
  /** The selection's last line: the right of its last character and that line's box. */
  end?: { right: number; top: number; bottom: number };
  /** The selection's last line's start: where `own-start` puts the chip. */
  lineStart?: number;
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
  const rect = (backward ? rects[0] : rects[rects.length - 1]) ?? range.getBoundingClientRect?.();
  if (!rect) return { text, left: 0, top: 0, bottom: 0 };
  const end = last ? { right: last.right, top: last.top, bottom: last.bottom } : undefined;
  return {
    text,
    left: backward ? rect.left : rect.right,
    top: rect.top,
    bottom: rect.bottom,
    end,
    lineStart: last?.left,
    column: columnOf(range.endContainer),
  };
}

export type PlaceRect = { left: number; top: number; right: number; bottom: number };
/// Where the chip goes; `compact` draws its glyph alone (a square), where its label would cover text.
export type SelectionReplyPlace = { left: number; top: number; compact?: boolean };
const PLACE_GAP = 6;
/// What the chip does when no spot near the selection's end is free of text (selectionReplyWrap).
export type SelectionReplyWrap = "own-end" | "own-start" | "farther";
/// The chip's margin inside the visible transcript's top and bottom.
const EDGE = 2;
/// How many lines past the rows next to the end the chip looks for a free spot.
const FARTHER = 3;

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

/// What text a spot would cover: the boxes of transcript text that is not selected and crosses
/// `box` (viewport px). The chip may cover the selection's own words, never anyone else's.
export type TextProbe = (box: PlaceRect) => readonly PlaceRect[];

const crosses = (a: PlaceRect, b: PlaceRect) =>
  Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
  Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;

/// A probe that asks the DOM at each spot: the transcript rows crossing it, their text nodes, and
/// of each the parts outside `range` (the selection). Nothing is measured ahead, so a spot far from
/// the selection's end, or near the other end of a backward drag, is measured where it is.
export function unselectedTextProbe(doc: Document, range: Range): TextProbe {
  const part = doc.createRange();
  return (box) => {
    const found: PlaceRect[] = [];
    const take = (node: Text, from: number, to: number) => {
      if (from >= to) return;
      part.setStart(node, from);
      part.setEnd(node, to);
      for (const rect of Array.from(part.getClientRects?.() ?? []))
        if (rect.width && rect.height && crosses(box, rect)) found.push(rect);
    };
    for (const row of Array.from(doc.querySelectorAll("[data-row-id]"))) {
      if (row.parentElement?.closest("[data-row-id]")) continue;
      const rowBox = row.getBoundingClientRect();
      if (!crosses(box, rowBox)) continue;
      const walker = doc.createTreeWalker(row, 4);
      for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null) {
        if (!node.data.trim()) continue;
        if (!range.intersectsNode(node)) {
          take(node, 0, node.length);
          continue;
        }
        // The selected part is [start, end): the rest of the node is someone else's text.
        const start = node === range.startContainer ? range.startOffset : 0;
        const end = node === range.endContainer ? range.endOffset : node.length;
        take(node, 0, start);
        take(node, end, node.length);
      }
    }
    return found;
  };
}

/// Where the chip goes, or undefined to hide it. Every candidate goes through one `accept`: it
/// slides the chip into its bounds, then takes the spot only when it is inside the visible
/// transcript (`pane`, from its top to its height) and `probe` finds no unselected text under it.
/// The bounds are the transcript column, or the pane where the column is narrower than the chip
/// (a short prompt in its bubble). A selection whose last line is not in the visible transcript
/// hides the chip until it scrolls back. Leo, 2026-11-05, on the chip drawn over a "Sent to" line:
/// "this is a bad reply"; and 2026-11-07: "if it's ever on the right edge, just make it in line ...
/// Sometimes it gets a bit strange, I guess. Like at the sides, because it's not aligned".
/// The candidates, in order:
///   1. Over the selection's end, centred on it (as Claude and ChatGPT do): unchanged wherever it
///      was free.
///   2. Inline: just after the selection's last character, centred on that line, when it fits
///      before the column's edge and the rest of the line is empty.
///   3. Just under the selection's last line, centred on its end (a paragraph break, a block's end).
///   4. The nearest free spot in the rows just above and just below the last line (`farther`: up
///      to three lines further each way).
///   5. Over the selection's own last words, centred on its last line: the person's own text
///      (`own-end` ends at the selection's end, `own-start` starts at its last line's start).
///   6. A free spot up to three lines away.
///   7. The chip's glyphs alone (`compact`: `size.compact` wide, else a square the chip's height)
///      over the selection's own last words, for a last line shorter than the chip in dense text.
export function selectionReplyPlace(
  target: SelectionReplyTarget,
  size: { width: number; height: number; compact?: number },
  pane: { width: number; height: number; top?: number },
  probe: TextProbe,
  wrap: SelectionReplyWrap = "own-end",
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

  /// The one exit: the spot slid into the bounds, if it is in view and over no one else's text.
  const accept = (x: number, y: number, w = width): SelectionReplyPlace | undefined => {
    const cx = Math.max(left, Math.min(x, right - w));
    const cy = Math.max(top + EDGE, Math.min(y, bottom - EDGE - height));
    const box = { left: cx, top: cy, right: cx + w, bottom: cy + height };
    if (box.left < left - 0.5 || box.right > right + 0.5 || box.top < top || box.bottom > bottom) return undefined;
    if (probe(box).length > 0) return undefined;
    return w < width ? { left: cx, top: cy, compact: true } : { left: cx, top: cy };
  };

  const line = (end.top + end.bottom - height) / 2;
  const under = end.bottom + gap;
  const step = Math.max(end.bottom - end.top, height / 2);
  const ownX = wrap === "own-start" && target.lineStart !== undefined ? target.lineStart : end.right - width;
  /// The rows `from` to `to` lines past those next to the last line, each measured once across the
  /// bounds: the spots that start or end at a gap's edge and cross no text there, nearest first.
  const rows = (from: number, to: number): [number, number][] => {
    const spots: { x: number; y: number; far: number }[] = [];
    for (let k = from; k <= to; k += 1)
      for (const y of [end.top - height - gap - k * step, under + k * step]) {
        if (y < top || y + height > bottom) continue;
        const band = probe({ left, right, top: y, bottom: y + height });
        const xs = [
          left,
          right - width,
          end.right - width / 2,
          ...band.flatMap((rect) => [rect.right + gap, rect.left - gap - width]),
        ];
        for (const x of xs) {
          const box = { left: x, top: y, right: x + width, bottom: y + height };
          if (x < left || x + width > right || band.some((rect) => crosses(box, rect))) continue;
          spots.push({ x, y, far: Math.abs(x + width / 2 - end.right) + Math.abs(y - line) });
        }
      }
    return spots.sort((a, b) => a.far - b.far).map(({ x, y }) => [x, y]);
  };
  function* candidates(): Generator<[number, number, number?]> {
    yield [target.left - width / 2, target.top - height - gap];
    if (end.right + gap + width <= right) yield [end.right + gap, line];
    yield [end.right - width / 2, under];
    yield* rows(0, wrap === "farther" ? FARTHER : 0);
    yield [ownX, line];
    if (wrap !== "farther") yield* rows(1, FARTHER);
    const glyphs = Math.min(size.compact ?? height, width);
    yield [wrap === "own-start" ? ownX : end.right - glyphs, line, glyphs];
  }
  for (const [x, y, w] of candidates()) {
    const place = accept(x, y, w);
    if (place) return place;
  }
  return undefined;
}
