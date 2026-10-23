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
// two end rows mounted (at most two) through one `selectionchange` listener, removed when the
// selection is cleared or no longer starts in its row, on the next margin press, or on unmount. One caret hit test per animation
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
/// starts, when it ends and when the selection lets go, never per move. Returns the uninstaller.
export function installGutterSelect(
  scroller: HTMLElement,
  thread: HTMLElement,
  onReaderScroll: () => void = () => {},
  hold: (rows: HeldRow[] | undefined) => void = () => {},
): () => void {
  const doc = scroller.ownerDocument;
  const win = doc.defaultView ?? window;
  type Drag = {
    startX: number;
    startY: number;
    x: number;
    y: number;
    geometry: GutterGeometry;
    anchor: Caret;
    selecting: boolean;
  };
  let drag: Drag | undefined;
  let frame = 0;
  /// Rows are held (`hold`) for the drag, or for the selection it left: the row its start lies in.
  let held: { row: HTMLElement } | undefined;
  const inThread = (caret: Caret | undefined): caret is Caret => caret != null && thread.contains(caret.node);
  const extend = (current: Drag) => {
    const point = clampIntoColumn(current.x, current.y, current.geometry);
    const focus = caretAt(doc, point.x, point.y);
    if (!inThread(focus) || !current.anchor.node.isConnected) return;
    doc.getSelection()?.setBaseAndExtent(current.anchor.node, current.anchor.offset, focus.node, focus.offset);
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
    extend(current);
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
    if (!held) return;
    held = undefined;
    hold(undefined);
  };
  function onSelectionChange() {
    const selection = doc.getSelection();
    const anchor = selection?.anchorNode;
    if (!held || !selection || selection.isCollapsed || !anchor || !held.row.contains(anchor)) release();
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
      hold(rows.map(heldRow).filter((row): row is HeldRow => row !== undefined));
      doc.addEventListener("selectionchange", onSelectionChange);
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
      const row = rowOf(current.anchor.node);
      const start = row && heldRow(row);
      if (row && start) {
        held = { row };
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
    // minimap, Find's bar or anything else drawn in the scroller.
    const target = event.target;
    if (target !== scroller && target !== thread && target !== thread.parentElement) return;
    const geometry = measure(scroller, thread);
    if (!geometry || !inGutter(event.clientX, geometry)) return;
    const point = clampIntoColumn(event.clientX, event.clientY, geometry);
    const anchor = caretAt(doc, point.x, point.y);
    if (!inThread(anchor)) return;
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
      anchor,
      selecting: false,
    };
    win.addEventListener("mousemove", onMove, true);
    win.addEventListener("mouseup", onUp, true);
    win.addEventListener("blur", stop);
    scroller.addEventListener("scroll", onScroll, { passive: true });
  };
  scroller.addEventListener("mousedown", onDown);
  return () => {
    scroller.removeEventListener("mousedown", onDown);
    drag = undefined;
    stop();
    release();
  };
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
