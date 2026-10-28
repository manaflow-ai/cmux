// A drag that starts in the transcript's side gutters (the empty margins either side of the centered
// column) selects text, as a document's margins do (Leo 2026-10-21: "i want click and drag to
// highlight text even when im just clicking on the left or right of the main pane").
//
// The browser cannot do this alone. The page is `user-select: none` with messages opting back in
// (shared/desktop.css), and the rows are absolutely placed (virtualized), so a press in the gutter
// hits the scroller or its spacer and the browser's own hit test finds no line beside it: no
// selection starts, and making the gutter selectable would anchor at the thread's start instead.
// So a press there is taken over: it starts nothing until the pointer moves, then selects from the
// caret beside the press to the caret under the pointer, both read with x clamped into the column.
// The press still takes focus off the composer as a press on the background always has (Leo
// 2026-10-20, composerFocus.ts); a plain click selects nothing.
//
// Stop conditions: the window and scroll listeners are added on a gutter press and removed on
// mouseup, on a move with the button up (released outside the page), on window blur, and when the
// transcript unmounts; the frame request is cancelled with them. A selection the drag left keeps its
// two end rows mounted (at most two) through one `selectionchange` listener and one MutationObserver
// on those rows' parents (childList only), both removed when the selection is cleared, no longer
// starts in its row or loses an end row, on the next margin press, on a chat change, or on unmount. One caret hit test per animation
// frame while the drag lasts, nothing per row. Edge scrolling repeats only while the pointer stays
// above or below the view during the drag, and stops at the view's end.

import { swallowsPress } from "../menuPressGuard";

/// A row kept mounted while a drag's selection starts in it: its id, and its index in the rows when
/// the drag started (read from the row's `aria-posinset`, so holding it walks no rows).
export type HeldRow = { id: string; index: number };

/// The column's left and right edges, and the view's box, in client coordinates.
export type GutterGeometry = {
  column: { left: number; right: number };
  view: { left: number; right: number; top: number; bottom: number };
  /// The scrollbar's lane at the view's right edge: a press there is the scrollbar's.
  lane: number;
};

/// How far the pointer moves before a press in the gutter becomes a selection, in CSS pixels; a
/// plain click does nothing (no selection, no focus change).
export const GUTTER_DRAG_THRESHOLD = 3;
/// The widest step an edge scroll takes in one frame, in CSS pixels.
const EDGE_SCROLL_MAX = 40;
/// The scrollbar lane when the scroller does not name one (conversation.css --acpmux-scrollbar-lane).
const DEFAULT_LANE = 16;

/// Whether `x` lies in a side gutter: inside the view, left or right of the column, and clear of
/// the scrollbar's lane.
export function inGutter(x: number, geometry: GutterGeometry): boolean {
  const { column, view, lane } = geometry;
  if (x < view.left || x >= view.right - lane) return false;
  return x < column.left || x > column.right;
}

/// A point moved into the column's content box (one pixel in from each edge), and into the view
/// above the bottom stack, where the caret hit test finds the text line at that height.
export function clampIntoColumn(x: number, y: number, geometry: GutterGeometry): { x: number; y: number } {
  const { column, view } = geometry;
  const clamp = (value: number, low: number, high: number) =>
    high - low < 2 ? (low + high) / 2 : Math.min(Math.max(value, low + 1), high - 1);
  return { x: clamp(x, column.left, column.right), y: clamp(y, view.top, view.bottom) };
}

/// Whether the pointer has moved far enough from the press to start a selection.
export function pastThreshold(dx: number, dy: number): boolean {
  return Math.hypot(dx, dy) >= GUTTER_DRAG_THRESHOLD;
}

/// The edge scroll for a pointer `y` outside the view: negative above, positive below, 0 inside.
export function edgeScrollStep(y: number, view: { top: number; bottom: number }): number {
  const past = y < view.top ? y - view.top : y > view.bottom ? y - view.bottom : 0;
  if (past === 0) return 0;
  const step = Math.min(EDGE_SCROLL_MAX, Math.max(2, Math.abs(past) / 2));
  return Math.sign(past) * step;
}

type Caret = { node: Node; offset: number };
type CaretDocument = Document & {
  caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
  caretRangeFromPoint?: (x: number, y: number) => Range | null;
};

/// The caret at a client point: the standard caretPositionFromPoint, else WebKit's and older
/// Chromium's caretRangeFromPoint.
export function caretAt(doc: Document, x: number, y: number): Caret | undefined {
  const caretDoc = doc as CaretDocument;
  if (typeof caretDoc.caretPositionFromPoint === "function") {
    const position = caretDoc.caretPositionFromPoint(x, y);
    if (position) return { node: position.offsetNode, offset: position.offset };
  }
  if (typeof caretDoc.caretRangeFromPoint === "function") {
    const range = caretDoc.caretRangeFromPoint(x, y);
    if (range) return { node: range.startContainer, offset: range.startOffset };
  }
  return undefined;
}

/// The gutter geometry now: the column from a mounted row (rows sit --cv-inset in, the column's
/// content box), the view from the scroller less the bottom stack laid over its foot.
function measure(scroller: HTMLElement, thread: HTMLElement): GutterGeometry | undefined {
  const row = thread.querySelector<HTMLElement>(".acpmux-row");
  if (!row) return undefined;
  const rowBox = row.getBoundingClientRect();
  const box = scroller.getBoundingClientRect();
  const style = getComputedStyle(scroller);
  const named = Number.parseFloat(style.getPropertyValue("--acpmux-scrollbar-lane"));
  const classic = scroller.offsetWidth - scroller.clientWidth;
  const dock = Number.parseFloat(scroller.style.getPropertyValue("--acpmux-dock-space")) || 0;
  return {
    column: { left: rowBox.left, right: rowBox.right },
    view: { left: box.left, right: box.right, top: box.top, bottom: Math.max(box.top, box.bottom - dock) },
    lane: Math.max(Number.isFinite(named) ? named : DEFAULT_LANE, classic),
  };
}

/// Installs gutter drag-to-select on the transcript's scroller. `thread` holds the rows; the
/// selection's ends always lie inside it. `onReaderScroll` is told of each step the drag scrolls the
/// view by, so the transcript takes it as the reader's own scroll (it stops following the latest
/// message) and does not pull the view back. `hold` keeps rows mounted that the transcript would
/// otherwise unmount as the view moves (it virtualizes rows, and a selection whose end unmounts
/// loses it): the row the selection starts in from the drag's first move, then both end rows once the
/// button lifts, until the selection is cleared or no longer starts there. It is called when the drag
/// starts, when it ends and when the selection lets go, never per move. Returns `release`, which ends
/// any drag and lets its rows go (the transcript calls it when it shows another chat), and `remove`,
/// the uninstaller.
export function installGutterSelect(
  scroller: HTMLElement,
  thread: HTMLElement,
  onReaderScroll: () => void = () => {},
  hold: (rows: HeldRow[] | undefined) => void = () => {},
  surface: HTMLElement | null = null,
): { release(): void; remove(): void } {
  const doc = scroller.ownerDocument;
  const win = doc.defaultView ?? window;
  // The floating composer is a sibling overlay of the scroller. Listen on their shared surface so a
  // blank location strip can start the same drag as the scroller's spacer, while keeping controls
  // (and the composer card) in charge of their own presses.
  const eventSurface = surface ?? scroller;
  type Drag = {
    startX: number;
    startY: number;
    x: number;
    y: number;
    geometry: GutterGeometry;
    /// Where the press reads, as a collapsed live Range: when the text under it changes while the
    /// button is held (a streaming reply redraws its markdown), the DOM moves the point with it
    /// (into the parent of a node taken out, or to the end of text that shrank), never out of range.
    anchor: Range;
    /// The row the press reads in. The start must stay inside it: a row taken out moves a live
    /// Range's point to the thread, which would start the selection somewhere else.
    row: HTMLElement;
    selecting: boolean;
  };
  let drag: Drag | undefined;
  let frame = 0;
  /// Rows are held (`hold`) for the drag, or for the selection it left: the row its start lies in,
  /// and once the button lifts the row its end lies in.
  let held: { row: HTMLElement; focus?: HTMLElement } | undefined;
  const inThread = (caret: Caret | undefined): caret is Caret => caret != null && thread.contains(caret.node);
  /// Moves the selection's end to the pointer. False once the start has left the transcript (its row
  /// was taken out), when the drag ends instead of scrolling on with nothing to select.
  const extend = (current: Drag): boolean => {
    const { startContainer, startOffset } = current.anchor;
    if (!current.row.isConnected || !thread.contains(current.row) || !current.row.contains(startContainer))
      return false;
    const point = clampIntoColumn(current.x, current.y, current.geometry);
    const focus = caretAt(doc, point.x, point.y);
    if (inThread(focus)) doc.getSelection()?.setBaseAndExtent(startContainer, startOffset, focus.node, focus.offset);
    return true;
  };
  const tick = () => {
    frame = 0;
    const current = drag;
    if (!current?.selecting) return;
    const step = edgeScrollStep(current.y, current.geometry.view);
    const before = scroller.scrollTop;
    if (step !== 0) {
      onReaderScroll();
      scroller.scrollTop = before + step;
    }
    if (!extend(current)) {
      stop();
      return;
    }
    // The pointer still past an edge keeps the view moving, one step a frame, until it comes back,
    // the view reaches its end, the button lifts or the window lets go.
    if (step !== 0 && scroller.scrollTop !== before) frame = win.requestAnimationFrame(tick);
  };
  /// The view scrolled under a still pointer (the wheel, or the edge scroll): the caret under it moved.
  const onScroll = () => {
    if (drag?.selecting && !frame) frame = win.requestAnimationFrame(tick);
  };
  /// Lets the held rows go: the selection was cleared, moved, or another press began.
  const release = () => {
    doc.removeEventListener("selectionchange", onSelectionChange);
    rowsGone.disconnect();
    if (!held) return;
    held = undefined;
    hold(undefined);
  };
  /// A held end row taken out (the message was removed): the selection's end moved with the DOM to
  /// somewhere the reader never chose, so it is cleared rather than left selecting other text. True
  /// when it did. (Browsers do not all send `selectionchange` for that move, so `rowsGone` asks too.)
  const clearIfRowGone = (): boolean => {
    if (!held || (held.row.isConnected && (!held.focus || held.focus.isConnected))) return false;
    const selection = doc.getSelection();
    const anchor = selection?.anchorNode;
    if (selection && anchor && thread.contains(anchor)) selection.removeAllRanges();
    release();
    return true;
  };
  /// Watches only the held rows' parents' own children (no subtree), from the button lifting until
  /// the selection lets go: one check of two nodes per batch of rows mounted or taken out.
  const rowsGone = new MutationObserver(() => clearIfRowGone());
  function onSelectionChange() {
    if (clearIfRowGone()) return;
    const selection = doc.getSelection();
    const anchor = selection?.anchorNode;
    // The selection was cleared, or moved off the rows the drag left it in (a Shift-click moved its
    // end elsewhere): it is the reader's own now, and the rows go back to being virtualized as for
    // any other selection.
    const focus = selection?.focusNode;
    if (
      !held ||
      !selection ||
      selection.isCollapsed ||
      !anchor ||
      !held.row.contains(anchor) ||
      (held.focus && (!focus || !held.focus.contains(focus)))
    )
      release();
  }
  /// Ends the drag. A selection it made keeps its end rows mounted until it lets go (`release`).
  const stop = () => {
    const current = drag;
    drag = undefined;
    const selection = doc.getSelection();
    const anchorRow = held?.row;
    if (current?.selecting && anchorRow?.isConnected && selection && !selection.isCollapsed) {
      const focusRow = rowOf(selection.focusNode);
      const rows = [anchorRow, ...(focusRow && focusRow !== anchorRow ? [focusRow] : [])];
      held = { row: anchorRow, focus: focusRow };
      hold(rows.map(heldRow).filter((row): row is HeldRow => row !== undefined));
      doc.addEventListener("selectionchange", onSelectionChange);
      for (const row of rows) if (row.parentNode) rowsGone.observe(row.parentNode, { childList: true });
    } else release();
    if (frame) win.cancelAnimationFrame(frame);
    frame = 0;
    win.removeEventListener("mousemove", onMove, true);
    win.removeEventListener("mouseup", onUp, true);
    win.removeEventListener("blur", stop);
    scroller.removeEventListener("scroll", onScroll);
  };
  function onMove(event: MouseEvent) {
    const current = drag;
    if (!current) return;
    // The button came up outside the page (no mouseup reached it).
    if ((event.buttons & 1) === 0) {
      stop();
      return;
    }
    current.x = event.clientX;
    current.y = event.clientY;
    if (!current.selecting) {
      if (!pastThreshold(current.x - current.startX, current.y - current.startY)) return;
      current.selecting = true;
      const start = heldRow(current.row);
      if (start) {
        held = { row: current.row };
        hold([start]);
      }
    }
    event.preventDefault();
    if (!frame) frame = win.requestAnimationFrame(tick);
  }
  function onUp(event: MouseEvent) {
    const current = drag;
    if (current?.selecting) {
      current.x = event.clientX;
      current.y = event.clientY;
      extend(current);
    } else if (current) {
      // A plain click in the margin selects nothing, and lets go of a selection in the transcript as
      // a click in a document's margin does. A field's caret (the composer's) stays.
      const selection = doc.getSelection();
      if (selection?.anchorNode && thread.contains(selection.anchorNode)) selection.removeAllRanges();
    }
    stop();
  }
  const onDown = (event: MouseEvent) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    // A press that only closes an open composer menu does nothing else (menuPressGuard.ts).
    if (swallowsPress(doc)) return;
    // Only the empty gutter: the scroller, its spacer and the thread's own box, never a row, the
    // minimap, Find's bar or anything else drawn in the scroller. The one overlay exception is the
    // blank composer location strip; its controls remain interactive and are filtered below.
    const target = event.target;
    const directTranscriptTarget = target === scroller || target === thread || target === thread.parentElement;
    const targetElement = target instanceof Element ? target : undefined;
    const strip = targetElement?.closest<HTMLElement>(".acpmux-composer-strip");
    const stripPress = Boolean(
      strip &&
      eventSurface.contains(strip) &&
      !targetElement?.closest(
        'button, a[href], input, textarea, select, label, summary, [contenteditable="true"], [role="button"], [role="link"], [role="menuitem"], [role="option"], [role="textbox"], [role="combobox"], [role="listbox"], [role="menu"], [role="dialog"]',
      ),
    );
    if (!directTranscriptTarget && !stripPress) return;
    const geometry = measure(scroller, thread);
    if (!geometry) return;
    // A spacer band under the last row is still part of the transcript, even when the x coordinate is
    // inside the centered column. The bottom stack's child strip is the overlay equivalent.
    const inBottomBand =
      event.clientY >= geometry.view.bottom &&
      event.clientX >= geometry.view.left &&
      event.clientX < geometry.view.right - geometry.lane;
    if (!inGutter(event.clientX, geometry) && !inBottomBand && !stripPress) return;
    const point = clampIntoColumn(event.clientX, event.clientY, geometry);
    const caret = caretAt(doc, point.x, point.y);
    // No text to start at (a hit beside a blank gap): the native press goes ahead untouched, and
    // moves focus off the composer to the page as it always has.
    const row = inThread(caret) ? rowOf(caret.node) : undefined;
    if (!caret || !row) return;
    // No native press: it would start no selection here. Focus leaves the composer (or a row) as
    // the native press on the background moved it, to the page.
    event.preventDefault();
    const active = doc.activeElement;
    if (active instanceof HTMLElement && active !== doc.body) active.blur();
    stop();
    release();
    drag = {
      startX: event.clientX,
      startY: event.clientY,
      x: event.clientX,
      y: event.clientY,
      geometry,
      anchor: anchorAt(doc, caret),
      row,
      selecting: false,
    };
    win.addEventListener("mousemove", onMove, true);
    win.addEventListener("mouseup", onUp, true);
    win.addEventListener("blur", stop);
    scroller.addEventListener("scroll", onScroll, { passive: true });
  };
  eventSurface.addEventListener("mousedown", onDown, true);
  /// Ends a drag without extending it, and lets every held row go.
  const end = () => {
    drag = undefined;
    stop();
    release();
  };
  return {
    release: end,
    remove: () => {
      eventSurface.removeEventListener("mousedown", onDown, true);
      end();
    },
  };
}

/// A collapsed live Range at `caret`.
function anchorAt(doc: Document, caret: Caret): Range {
  const range = doc.createRange();
  range.setStart(caret.node, caret.offset);
  range.collapse(true);
  return range;
}

/// The transcript row holding `node`.
function rowOf(node: Node | null | undefined): HTMLElement | undefined {
  const element = node instanceof Element ? node : node?.parentElement;
  return element?.closest<HTMLElement>(".acpmux-row") ?? undefined;
}

/// A row to hold: its id and index, read from its own attributes (no walk of the rows).
function heldRow(row: HTMLElement): HeldRow | undefined {
  const index = Number(row.getAttribute("aria-posinset")) - 1;
  const id = row.dataset.rowId;
  return id && index >= 0 ? { id, index } : undefined;
}
