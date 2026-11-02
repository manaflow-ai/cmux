// A drag that starts in the transcript's side gutters or its empty row spacing selects text, as a
// document's margins and line gaps do (Leo 2026-10-21: "i want click and drag to highlight text even
// when im just clicking on the left or right of the main pane").
//
// The browser cannot do this alone. The page is `user-select: none` with messages opting back in
// (shared/desktop.css), and the rows are absolutely placed (virtualized), so a press in the gutter
// hits the scroller or its spacer and the browser's own hit test finds no line beside it: no
// selection starts, and making the gutter selectable would anchor at the thread's start instead.
// So a press there is taken over: it starts nothing until the pointer moves, then selects from the
// nearest mounted caret beside the press to the caret under the pointer, both read with x clamped
// into the column.
// The press still takes focus off the composer as a press on the background always has (Leo
// 2026-10-20, composerFocus.ts); a plain click selects nothing.
//
// Stop conditions: the window and scroll listeners are added on a gutter or gap press and removed on
// pointerup, on a move with the button up (released outside the page), on window blur, and when the
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

// Composer strips contain a full-width layout context around their actual controls. Keep those
// controls (and their padding) under native pointer ownership while allowing a drag from the
// context's blank room to use the transcript selection path.
const INTERACTIVE_TARGETS =
  'button, a[href], input, textarea, select, label, summary, [contenteditable="true"], [draggable="true"], [data-interactive], [role="button"], [role="link"], [role="menuitem"], [role="option"], [role="textbox"], [role="combobox"], [role="listbox"], [role="menu"], [role="dialog"]';

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

/// A transcript surface can paint selectable code inside an open shadow root (@pierre/diffs).
/// Events retargeted to its host still carry the composed path, so leave those presses to the
/// browser's native shadow selection instead of treating the host's row padding as a gap.
function shadowTextPress(event: PointerEvent): boolean {
  return event.composedPath().some((part) => {
    if (typeof ShadowRoot !== "undefined" && part instanceof ShadowRoot) return true;
    if (part instanceof Node && part.getRootNode() instanceof ShadowRoot) return true;
    return part instanceof Element && part.shadowRoot !== null;
  });
}

type CaretHit = { caret: Caret; row: HTMLElement };

/// A text node that the browser would include in a native selection. Mounted rows are bounded by
/// virtualization; this check is only used during the one pointerdown that resolves a gap anchor.
function selectableTextNode(node: Node): boolean {
  const element = node.parentElement;
  if (!element || !node.textContent?.trim()) return false;
  const select = getComputedStyle(element);
  if (select.userSelect === "none" || select.getPropertyValue("-webkit-user-select") === "none") return false;
  for (let current: HTMLElement | null = element; current; current = current.parentElement) {
    const style = getComputedStyle(current);
    if (style.visibility === "hidden" || style.pointerEvents === "none" || Number.parseFloat(style.opacity) <= 0)
      return false;
    if (current.classList.contains("acpmux-row")) break;
  }
  return true;
}

/// Native selection already owns a press on rendered selectable text. An element's padding can
/// have the same event target as its text, so use the actual text rectangles to distinguish it.
function hitsText(doc: Document, thread: HTMLElement, x: number, y: number): boolean {
  const caret = caretAt(doc, x, y);
  if (!caret || caret.node.nodeType !== 3 || !thread.contains(caret.node) || !selectableTextNode(caret.node))
    return false;
  const range = doc.createRange();
  range.selectNodeContents(caret.node);
  return Array.from(range.getClientRects()).some(
    (rect) => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom,
  );
}

/// Finds the closest visible text line around a gap. A line above contributes its end caret, a line
/// below its start caret; a side gutter uses the line edge nearest that gutter. It walks only the
/// mounted thread subtree, once at pointerdown, and never runs in the drag's animation-frame path.
function nearestCaretAtPoint(
  doc: Document,
  thread: HTMLElement,
  x: number,
  y: number,
  view: GutterGeometry["view"],
): CaretHit | undefined {
  const walker = doc.createTreeWalker(thread, 4);
  let best:
    | { distance: number; boundary: "above" | "below" | "inside"; edge: number; node: Node; x: number; y: number }
    | undefined;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!selectableTextNode(node)) continue;
    if (!rowOf(node)) continue;
    const range = doc.createRange();
    range.selectNodeContents(node);
    const rtl = getComputedStyle(node.parentElement!).direction === "rtl";
    for (const rect of Array.from(range.getClientRects())) {
      if (rect.width <= 0 || rect.height <= 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
      const above = y >= rect.bottom;
      const below = y <= rect.top;
      const distance = above ? y - rect.bottom : below ? rect.top - y : 0;
      const startX = rtl ? rect.right - 0.5 : rect.left + 0.5;
      const endX = rtl ? rect.left + 0.5 : rect.right - 0.5;
      const lineX = above ? endX : below ? startX : Math.min(Math.max(x, rect.left + 0.5), rect.right - 0.5);
      const horizontal = Math.max(rect.left - x, x - rect.right, 0);
      const edge = above ? (rtl ? rect.left : -rect.right) : below ? (rtl ? -rect.right : rect.left) : horizontal;
      // Prefer the nearest line. An exact midpoint picks the line above so its end is the stable
      // document-style anchor; moving toward the next row then extends in the expected direction.
      if (
        !best ||
        distance < best.distance - 0.01 ||
        (Math.abs(distance - best.distance) <= 0.01 &&
          ((above && best.boundary !== "above") ||
            (!above && !below && best.boundary === "below") ||
            (above === (best.boundary === "above") && edge < best.edge)))
      ) {
        best = {
          distance,
          boundary: above ? "above" : below ? "below" : "inside",
          edge,
          node,
          x: lineX,
          y: Math.min(Math.max(rect.top + rect.height / 2, view.top + 1), view.bottom - 1),
        };
      }
    }
  }
  const caret = best
    ? best.boundary === "above"
      ? { node: best.node, offset: best.node.textContent?.length ?? 0 }
      : best.boundary === "below"
        ? { node: best.node, offset: 0 }
        : caretAt(doc, best.x, best.y)
    : undefined;
  const row = caret && thread.contains(caret.node) ? rowOf(caret.node) : undefined;
  return caret && row ? { caret, row } : undefined;
}

/// The caret in a transcript row at a client point. Over a blank band (below the last row, or
/// between rows) Chromium's hit test snaps to the nearest line, but WebKit's (the app's engine)
/// returns the spacer at offset 0, which reads as the thread's start; so the point is tried again
/// inside the mounted row at that height (the last one starting above it, else the first), where
/// both engines find the line nearest it: a row's end below its text, its start above.
function rowCaretAt(doc: Document, thread: HTMLElement, x: number, y: number): Caret | undefined {
  const caret = caretAt(doc, x, y);
  // Rows are absolutely placed, so their order is read from their boxes, not the DOM.
  if (caret && thread.contains(caret.node) && rowOf(caret.node)) return caret;
  let row: { node: HTMLElement; box: DOMRect } | undefined;
  for (const node of thread.querySelectorAll<HTMLElement>(".acpmux-row")) {
    const box = node.getBoundingClientRect();
    if (box.height <= 0) continue;
    const better = !row
      ? true
      : box.top <= y
        ? row.box.top > y || box.top > row.box.top
        : row.box.top > y && box.top < row.box.top;
    if (better) row = { node, box };
  }
  if (!row) return caret;
  const { box } = row;
  const inRow = caretAt(doc, x, Math.min(Math.max(y, box.top + 1), box.bottom - 1));
  return inRow && row.node.contains(inRow.node) ? inRow : caret;
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
    pointerId: number;
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
    const focus = rowCaretAt(doc, thread, point.x, point.y);
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
    win.removeEventListener("pointermove", onMove, true);
    win.removeEventListener("pointerup", onUp, true);
    win.removeEventListener("pointercancel", stop, true);
    win.removeEventListener("blur", stop);
    scroller.removeEventListener("scroll", onScroll);
  };
  function onMove(event: PointerEvent) {
    const current = drag;
    if (!current || event.pointerId !== current.pointerId) return;
    // The button came up outside the page (no pointerup reached it).
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
  function onUp(event: PointerEvent) {
    const current = drag;
    if (current && event.pointerId !== current.pointerId) return;
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
  const onDown = (event: PointerEvent) => {
    if (
      event.button !== 0 ||
      event.pointerType === "touch" ||
      event.isPrimary === false ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      event.shiftKey
    )
      return;
    // Before classifying the target as row padding, preserve native ownership for any text surface
    // painted in an open shadow root. The shadow component owns its own selection; this handler
    // does not attempt to synthesize a range across that boundary.
    if (shadowTextPress(event)) return;
    // A press that only closes an open composer menu does nothing else (menuPressGuard.ts).
    if (swallowsPress(doc)) return;
    // Own only known empty layout boxes, never a content element or its descendants. Row-local
    // padding has an explicit hit target, so native media and future content need no denylist.
    const target = event.target;
    const directTranscriptTarget = target === scroller || target === thread || target === thread.parentElement;
    const targetElement = target instanceof Element ? target : undefined;
    const rowGapPress = Boolean(
      targetElement?.closest<HTMLElement>("[data-transcript-gap='row']") &&
      thread.contains(targetElement.closest("[data-transcript-gap='row']")),
    );
    // A blank box that is the row's room (a reply's action row over a status row) counts only when
    // the press lands on the box itself, never on one of its controls.
    const blankPress = Boolean(
      targetElement?.getAttribute("data-transcript-gap") === "blank" && thread.contains(targetElement),
    );
    const strip = targetElement?.closest<HTMLElement>(".acpmux-composer-strip");
    const stripPress = Boolean(
      strip &&
      eventSurface.contains(strip) &&
      !targetElement?.closest(INTERACTIVE_TARGETS) &&
      !targetElement?.closest(".acpmux-location-readonly"),
    );
    if (!directTranscriptTarget && !stripPress && !rowGapPress && !blankPress) return;
    const geometry = measure(scroller, thread);
    if (!geometry) return;
    // A spacer band under the last row is still part of the transcript, even when the x coordinate is
    // inside the centered column. The bottom stack's child strip is the overlay equivalent.
    const inBottomBand =
      event.clientY >= geometry.view.bottom &&
      event.clientX >= geometry.view.left &&
      event.clientX < geometry.view.right - geometry.lane;
    const sideGutter = inGutter(event.clientX, geometry);
    const inColumn = event.clientX >= geometry.column.left && event.clientX <= geometry.column.right;
    const transcriptGap =
      rowGapPress || blankPress || inBottomBand || stripPress || (directTranscriptTarget && inColumn && !sideGutter);
    if (!sideGutter && !transcriptGap) return;
    if ((rowGapPress || blankPress) && hitsText(doc, thread, event.clientX, event.clientY)) return;
    const point = clampIntoColumn(event.clientX, event.clientY, geometry);
    const resolved = nearestCaretAtPoint(doc, thread, point.x, point.y, geometry.view);
    // A plain click in a gap with no mounted text clears an existing transcript selection, while
    // leaving the browser's normal background focus behavior untouched.
    if (!resolved) {
      stop();
      release();
      const selection = doc.getSelection();
      if (selection?.anchorNode && thread.contains(selection.anchorNode)) selection.removeAllRanges();
      return;
    }
    const { caret, row } = resolved;
    // No native press: it would start no selection here. Focus leaves the composer (or a row) as
    // the native press on the background moved it, to the page.
    event.preventDefault();
    const active = doc.activeElement;
    if (active instanceof HTMLElement && active !== doc.body) active.blur();
    stop();
    release();
    drag = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      x: event.clientX,
      y: event.clientY,
      geometry,
      anchor: anchorAt(doc, caret),
      row,
      selecting: false,
    };
    win.addEventListener("pointermove", onMove, true);
    win.addEventListener("pointerup", onUp, true);
    win.addEventListener("pointercancel", stop, true);
    win.addEventListener("blur", stop);
    scroller.addEventListener("scroll", onScroll, { passive: true });
  };
  eventSurface.addEventListener("pointerdown", onDown, true);
  /// Ends a drag without extending it, and lets every held row go.
  const end = () => {
    drag = undefined;
    stop();
    release();
  };
  return {
    release: end,
    remove: () => {
      eventSurface.removeEventListener("pointerdown", onDown, true);
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
