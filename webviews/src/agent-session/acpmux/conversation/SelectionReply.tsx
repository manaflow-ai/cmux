// Reply to a part of a message: selecting transcript text shows a small Reply chip above the
// selection's end; where that spot holds text (the line before, a "Sent to" line over the reply) it
// takes the nearest spot that covers no other text (selectionReplyPlace). It never floats in the
// margin past the column or leaves the visible transcript; clicking it quotes the selection into the composer,
// the same Quote in Reply the selection's right-click menu runs (AgentPaneContextMenu.swift
// `quote`, App.tsx `chat.quoteReply`). Leo, 2026-11-03: "would it make sense to have a direct
// reply button? or would you mostly just re-read your own thing anyways? what makes sense here?"
//
// The chip shows when a selection ends (pointer or key up), with no fade-in, and goes as soon as
// the selection collapses or leaves the transcript. It never shows for text in the composer (any
// editable field), in a code block (selected to copy) or in a read-only transcript. It does no
// work per token: it reads the DOM only on a selection's end and while it is shown.
//
// How it looks is a trial the theme can carry (`theme.selectionReply`, the gallery's
// agent-pane.selection-reply): `chip` (the default: quote glyph and "Reply"), `icon` (glyph only),
// `none` (the right-click menu alone) and `row` (a Reply button on every message's action row,
// kept to show why the chip won).
import { useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { Quote } from "./icons";
import { selectionReplyWrap } from "./selectionReplyWrap.experiment";

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
  const text = selection.toString().trim();
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
///   7. The chip's glyph alone (`compact`, a square the chip's height) over the selection's own
///      last words, for a last line shorter than the chip in dense text.
export function selectionReplyPlace(
  target: SelectionReplyTarget,
  size: { width: number; height: number },
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
    yield [wrap === "own-start" ? ownX : end.right - height, line, height];
  }
  for (const [x, y, w] of candidates()) {
    const place = accept(x, y, w);
    if (place) return place;
  }
  return undefined;
}

/// A Reply button for a message's action row (`row` look only), its glyph the row's 16 px
/// (MessageActions.tsx ROW_ICON).
export function RowReplyButton({ text }: { text: string }) {
  const t = useT();
  if (useSelectionReplyLook() !== "row" || !text) return null;
  const label = t("message.quoteReply");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-label={label}
      title={label}
      onClick={() => quoteInReply(text)}
    >
      <Quote size={16} />
    </button>
  );
}

/// The chip over the selection's end. Mounted once per pane (App.tsx), on the document's body.
export function SelectionReplyChip({ doc = document }: { doc?: Document }) {
  const t = useT();
  const current = useSelectionReplyLook();
  const enabled = current === "chip" || current === "icon";
  const [target, setTarget] = useState<SelectionReplyTarget>();
  const shown = useRef(false);
  shown.current = target !== undefined;
  const chip = useRef<HTMLButtonElement>(null);
  // Undefined while the chip is measured; null where no spot takes it (it hides).
  const [placed, setPlaced] = useState<SelectionReplyPlace | null>();
  // The chip's width with its label: a compact chip is narrower, and the next placement (a scroll)
  // must try the full chip first.
  const fullWidth = useRef(0);

  useEffect(() => {
    if (!enabled) {
      setTarget(undefined);
      return;
    }
    const view = doc.defaultView;
    // A selection's end shows the chip: the pointer let go, or a Shift-arrow key came up.
    const ended = () => setTarget(selectionReplyTarget(doc));
    const keyUp = (event: KeyboardEvent) => {
      if (event.shiftKey || event.key === "Shift" || ((event.metaKey || event.ctrlKey) && event.key === "a")) ended();
    };
    // While shown, a collapsed or changed selection hides it now; it never shows mid-drag.
    const changed = () => {
      if (!shown.current) return;
      const next = selectionReplyTarget(doc);
      if (!next) setTarget(undefined);
    };
    const scrolled = () => {
      if (shown.current) setTarget(selectionReplyTarget(doc));
    };
    doc.addEventListener("pointerup", ended);
    doc.addEventListener("keyup", keyUp);
    doc.addEventListener("selectionchange", changed);
    view?.addEventListener("scroll", scrolled, true);
    view?.addEventListener("resize", scrolled);
    return () => {
      doc.removeEventListener("pointerup", ended);
      doc.removeEventListener("keyup", keyUp);
      doc.removeEventListener("selectionchange", changed);
      view?.removeEventListener("scroll", scrolled, true);
      view?.removeEventListener("resize", scrolled);
    };
  }, [doc, enabled]);

  // Where no transcript text is under it (selectionReplyPlace), read once per shown selection.
  useLayoutEffect(() => {
    if (!target) return setPlaced(undefined);
    if (chip.current && chip.current.dataset.compact !== "true") fullWidth.current = chip.current.offsetWidth;
    const size = { width: fullWidth.current, height: chip.current?.offsetHeight ?? 0 };
    const selection = doc.getSelection();
    const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
    if (!range) return setPlaced(undefined);
    const clip = transcriptClip(doc, range.endContainer);
    const pane = {
      width: doc.documentElement.clientWidth || doc.defaultView?.innerWidth || 0,
      height: clip.bottom,
      top: clip.top,
    };
    setPlaced(
      selectionReplyPlace(target, size, pane, unselectedTextProbe(doc, range), experimentArm(selectionReplyWrap)) ??
        null,
    );
  }, [doc, target]);

  const quote = useCallback(() => {
    if (!target) return;
    // Clear the transcript selection first: quoting focuses the composer with its caret under the
    // quote, and clearing after would take that caret too. A quote that fails gets its range back.
    const selection = doc.getSelection();
    const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
    selection?.removeAllRanges();
    if (!quoteInReply(target.text) && range) selection?.addRange(range);
    setTarget(undefined);
  }, [doc, target]);

  if (!enabled || !target) return null;
  const label = t("message.quoteReply");
  // Its glyph alone where its label would cover someone else's words (selectionReplyPlace step 6).
  const compact = placed?.compact === true;
  const hidden = placed === null;
  return createPortal(
    <button
      ref={chip}
      type="button"
      className="cv-selection-reply"
      data-look={compact ? "icon" : current}
      data-compact={compact ? "true" : undefined}
      data-hidden={hidden ? "true" : undefined}
      aria-hidden={hidden ? true : undefined}
      aria-label={label}
      title={current === "icon" || compact ? label : undefined}
      style={
        placed
          ? { left: placed.left, top: placed.top }
          : { visibility: "hidden", pointerEvents: "none", left: 0, top: 0 }
      }
      // Pressing the chip keeps the selection it quotes.
      onPointerDown={(event) => event.preventDefault()}
      onMouseDown={(event) => event.preventDefault()}
      onClick={quote}
    >
      <Quote size={14} />
      {current === "chip" && !compact && <span>{label}</span>}
    </button>,
    doc.body,
  );
}
