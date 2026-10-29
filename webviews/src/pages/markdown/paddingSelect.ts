// A press in the page's padding selects text like a native text view (user 2026-10-27: "You should
// be able to click from the padding part and still be able to select the text properly").
//
// The reading column (`.md-doc`) has padding on every side and sits centered in the scroller
// (`.md-scroll`), so most of a wide pane is gutter. A press there lands outside the editable
// element (`.md-prose`): Chromium started no selection at all, WebKit anchored it at an arbitrary
// offset, and double and triple click selected nothing. Here a press on the gutter or the column's
// padding maps to the nearest text position: beside a line it is the line's start or end, above the
// first block the document's start, below the last block its end. A drag extends from it (and
// scrolls the page when the pointer leaves it), double click selects the nearest word, triple click
// its block, and Shift-click extends the current selection. It sets the DOM selection, which
// ProseMirror reads back, so a read-only file (not editable) selects the same way.
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import { markPointerDown } from "./pointerSelect";

const paddingSelectKey = new PluginKey("cmuxMarkdownPaddingSelect");
const WORDS = new Intl.Segmenter(undefined, { granularity: "word" });
/** How far past the scroller's edge the pointer is before a drag scrolls at full speed. */
const SCROLL_RAMP = 60;
/** Pixels per frame at full speed. */
const SCROLL_MAX = 24;

/** The document position nearest a viewport point, for a point outside the editable element. */
export function nearestPosition(view: EditorView, x: number, y: number): number {
  const doc = view.state.doc;
  const blocks = view.dom.getBoundingClientRect();
  if (y < blocks.top) return textStart(view, 0);
  if (y >= blocks.bottom) return textEnd(view, doc.content.size);
  const clampedX = Math.min(Math.max(x, blocks.left + 1), blocks.right - 1);
  const found = view.posAtCoords({ left: clampedX, top: y });
  if (!found) return x < blocks.left ? textStart(view, 0) : textEnd(view, doc.content.size);
  return found.pos;
}

/** The first text position at or after `pos` (a block's start, not between blocks). */
function textStart(view: EditorView, pos: number): number {
  const doc = view.state.doc;
  let found = -1;
  doc.nodesBetween(pos, doc.content.size, (node, at) => {
    if (found >= 0) return false;
    if (node.isTextblock) {
      found = at + 1;
      return false;
    }
    return true;
  });
  return found >= 0 ? found : pos;
}

/** The last text position at or before `pos`. */
function textEnd(view: EditorView, pos: number): number {
  let found = -1;
  view.state.doc.nodesBetween(0, pos, (node, at) => {
    if (node.isTextblock) found = at + 1 + node.content.size;
    return true;
  });
  return found >= 0 ? found : pos;
}

/** The word nearest `pos` in its textblock: the one it is in, else the one before, else after. */
export function wordAround(view: EditorView, pos: number): { from: number; to: number } {
  const $pos = view.state.doc.resolve(pos);
  if (!$pos.parent.isTextblock) return { from: pos, to: pos };
  // One character per inline leaf (math, an image), so string offsets are parent offsets.
  const text = $pos.parent.textBetween(0, $pos.parent.content.size, undefined, "￼");
  const offset = $pos.parentOffset;
  let before: Intl.SegmentData | undefined;
  let after: Intl.SegmentData | undefined;
  for (const segment of WORDS.segment(text)) {
    if (!segment.isWordLike) continue;
    const end = segment.index + segment.segment.length;
    if (segment.index <= offset && offset < end) {
      before = segment;
      after = undefined;
      break;
    }
    if (end <= offset) before = segment;
    else if (!after) after = segment;
  }
  // Beside a line's start the next word is nearest; beside its end, the last one.
  const word = offset === 0 ? (after ?? before) : (before ?? after);
  if (!word) return { from: pos, to: pos };
  const start = $pos.start();
  return { from: start + word.index, to: start + word.index + word.segment.length };
}

/** The textblock holding `pos`, start to end. */
function blockAround(view: EditorView, pos: number): { from: number; to: number } {
  const $pos = view.state.doc.resolve(pos);
  return $pos.parent.isTextblock ? { from: $pos.start(), to: $pos.end() } : { from: pos, to: pos };
}

function select(view: EditorView, anchor: number, head: number): void {
  const selection = view.dom.ownerDocument.getSelection();
  if (!selection) return;
  const from = view.domAtPos(anchor);
  const to = view.domAtPos(head);
  selection.setBaseAndExtent(from.node, from.offset, to.node, to.offset);
}

/** The anchor Shift-click extends from: the DOM selection's, when it is in the document. */
function currentAnchor(view: EditorView): number | undefined {
  const selection = view.dom.ownerDocument.getSelection();
  if (!selection?.anchorNode || !view.dom.contains(selection.anchorNode)) return undefined;
  try {
    return view.posAtDOM(selection.anchorNode, selection.anchorOffset);
  } catch {
    return undefined;
  }
}

/** Whether a press on `target` is in the padding around the document: the scroller or a box holding the editor. */
function inPadding(view: EditorView, scroller: Element, target: Element): boolean {
  if (!scroller.contains(target) || view.dom.contains(target)) return false;
  return target === scroller || target.contains(view.dom);
}

function onPress(view: EditorView, event: MouseEvent): void {
  if (event.button !== 0 || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
  const scroller = view.dom.closest(".md-scroll");
  const target = event.target;
  if (!scroller || !(target instanceof Element) || !inPadding(view, scroller, target)) return;
  // The source editor (Edit mode) hides the rich document.
  if (view.dom.getClientRects().length === 0) return;
  // A press on the scroller's own scrollbar scrolls; it never selects.
  const box = scroller.getBoundingClientRect();
  if (event.clientX >= box.left + scroller.clientLeft + scroller.clientWidth) return;
  if (event.clientY >= box.top + scroller.clientTop + scroller.clientHeight) return;

  event.preventDefault();
  if (view.editable && !view.hasFocus()) (view.dom as HTMLElement).focus({ preventScroll: true });
  markPointerDown(view);

  const pos = nearestPosition(view, event.clientX, event.clientY);
  let anchor: number;
  let head: number;
  let unit: "char" | "word" | "block" = "char";
  if (event.detail >= 3) {
    unit = "block";
    ({ from: anchor, to: head } = blockAround(view, pos));
  } else if (event.detail === 2) {
    unit = "word";
    ({ from: anchor, to: head } = wordAround(view, pos));
  } else {
    anchor = (event.shiftKey ? currentAnchor(view) : undefined) ?? pos;
    head = pos;
  }
  select(view, anchor, head);
  if (unit !== "char") return;

  // The drag: extends from the anchor to the pointer, scrolling while the pointer is past an edge.
  const window = view.dom.ownerDocument.defaultView!;
  let pointer = { x: event.clientX, y: event.clientY };
  let frame = 0;
  const extend = () => {
    if (view.isDestroyed) return;
    select(view, anchor, nearestPosition(view, pointer.x, pointer.y));
  };
  const autoscroll = () => {
    frame = 0;
    const edge = scroller.getBoundingClientRect();
    const over = pointer.y < edge.top ? pointer.y - edge.top : pointer.y > edge.bottom ? pointer.y - edge.bottom : 0;
    if (over === 0) return;
    const step =
      Math.sign(over) * Math.max(1, Math.round((Math.min(Math.abs(over), SCROLL_RAMP) / SCROLL_RAMP) * SCROLL_MAX));
    const before = scroller.scrollTop;
    scroller.scrollTop += step;
    if (scroller.scrollTop === before) return;
    extend();
    frame = window.requestAnimationFrame(autoscroll);
  };
  const move = (moved: MouseEvent) => {
    if (moved.buttons === 0) return release();
    pointer = { x: moved.clientX, y: moved.clientY };
    extend();
    if (!frame) frame = window.requestAnimationFrame(autoscroll);
  };
  // The release point ends the drag, as a native text view's: a busy engine can coalesce or drop
  // the last mousemove, which left the selection short of where the button came up.
  const release = (up?: Event) => {
    if (up instanceof MouseEvent && up.type === "mouseup") {
      pointer = { x: up.clientX, y: up.clientY };
      extend();
    }
    if (frame) window.cancelAnimationFrame(frame);
    frame = 0;
    window.removeEventListener("mousemove", move, true);
    window.removeEventListener("mouseup", release, true);
    window.removeEventListener("blur", release);
  };
  window.addEventListener("mousemove", move, true);
  window.addEventListener("mouseup", release, true);
  window.addEventListener("blur", release);
}

/** Selects text from a press in the padding around the document (see the file comment). */
export const paddingSelectPlugin = $prose(
  () =>
    new Plugin({
      key: paddingSelectKey,
      view(view) {
        const document = view.dom.ownerDocument;
        const press = (event: MouseEvent) => onPress(view, event);
        document.addEventListener("mousedown", press);
        return { destroy: () => document.removeEventListener("mousedown", press) };
      },
    }),
);
