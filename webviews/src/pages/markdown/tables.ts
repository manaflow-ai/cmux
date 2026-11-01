// Tables in the markdown editor, as Obsidian's (MARKDOWN-OBSIDIAN-PARITY, PARITY.md):
//
// - Keys: Return goes to the cell below and adds a row under the last one, Tab past the last cell
//   adds a row, Cmd-A selects the cell's text and then the whole table, Escape drops a cell
//   selection to a caret.
// - Copying a cell selection writes a Markdown table (text/plain) and an HTML table (text/html, for
//   spreadsheets).
// - A click places the caret; a drag and a Shift-click select text, also across cells, as in Safari
//   and the rest of the document (user 2026-10-28: snapping to whole cells was "extremely
//   unintuitive"). Whole cells are selected by Cmd-A, and Shift-click extends such a selection.
// - A drag that starts in a cell and leaves the table selects text from the press to the pointer
//   (MARKDOWN-SELECTION). prosemirror-tables kept a one-cell selection for the rest of such a drag:
//   it holds the selection while its drag runs and finds no cell under the pointer.
// - Column widths: a handle on each column's right edge; a drag sets the width, a double-click fits
//   the column to its content. Widths are a view setting kept per file (`TableWidths`), never
//   written to the file: GFM has no column widths, and a resize must not mark the file edited.
import type { Node as ProseNode, ResolvedPos, Schema } from "@milkdown/kit/prose/model";
import { AllSelection, Plugin, TextSelection, type EditorState, type Selection } from "@milkdown/kit/prose/state";
import {
  CellSelection,
  TableMap,
  TableView,
  findTable,
  goToNextCell,
  isInTable,
  selectedRect,
  tableEditingKey,
} from "@milkdown/kit/prose/tables";
import type { EditorView, ViewMutationRecord } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import { SIDEWAYS_SCROLLER_ATTRIBUTE } from "../../scrollers";

/**
 * Column widths, in CSS pixels, for each table of the open file. A table is known by its index in
 * the file and the key of its header row (`headerKey`): an edit elsewhere keeps its widths, a table
 * added above it moves its widths with it, and a changed header drops them
 * (plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md).
 */
export interface TableWidths {
  /** The saved widths of table `index` with header `header`, one per column, or null. */
  get(index: number, header: string): number[] | null;
  /**
   * Saves (or with null forgets) the widths of table `index`. `live` is every table's header key
   * in the file now, in order: a saved table no longer among them is dropped in the same write.
   */
  set(index: number, header: string, widths: number[] | null, live: readonly string[]): void;
  /** Forgets the widths of every table of the open file. */
  clear(): void;
  /** Calls `listener` after `clear` (each table view lays itself out again); returns the unsubscribe. */
  subscribe(listener: () => void): () => void;
}

/** One saved table: index `i`, header key `h`, widths `w`. */
export interface SavedTable {
  i: number;
  h: string;
  w: number[];
}

/** The value a file's widths are kept as (the host stores it as is: `cmux.markdown.setTableWidths`). */
export interface SavedTableWidths {
  v: 1;
  tables: SavedTable[];
}

/** The most tables and columns one file keeps (the host refuses more than 256 of either). */
const MAX_TABLES = 128;
const MAX_COLUMNS = 128;

/** A short key of a table's header row: its cell texts (FNV-1a, 32 bits, hex) and column count. */
export function headerKey(cells: readonly string[]): string {
  let hash = 0x811c9dc5;
  for (const char of cells.join("\u001f")) {
    hash ^= char.codePointAt(0)!;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `${cells.length}-${hash.toString(16).padStart(8, "0")}`;
}

/** The saved tables in `value`, or [] when it is not a `SavedTableWidths`. */
export function parseSavedTableWidths(value: unknown): SavedTable[] {
  const tables = (value as Partial<SavedTableWidths> | null)?.tables;
  if ((value as Partial<SavedTableWidths> | null)?.v !== 1 || !Array.isArray(tables)) return [];
  return tables.filter(
    (table): table is SavedTable =>
      Number.isInteger(table?.i) &&
      table.i >= 0 &&
      typeof table.h === "string" &&
      Array.isArray(table.w) &&
      table.w.length > 0 &&
      table.w.every((width: unknown) => typeof width === "number" && width > 0),
  );
}

/** Where a file's tables are loaded from and saved to. `save(path, null)` forgets the file. */
export interface TableWidthBackend {
  load(path: string): SavedTable[];
  save(path: string, value: SavedTableWidths | null): void;
}

/**
 * `TableWidths` over a backend, for the file `path()` names (read on each call: link navigation
 * changes the file). Each file's tables are loaded once and kept; each `set` or `clear` is one
 * backend save, so a column drag (one `set` when it ends) is one write.
 */
export function tableWidthsOver(path: () => string | undefined, backend: TableWidthBackend): TableWidths {
  const files = new Map<string, SavedTable[]>();
  const listeners = new Set<() => void>();
  const tables = (file: string) => {
    let saved = files.get(file);
    if (!saved) files.set(file, (saved = backend.load(file)));
    return saved;
  };
  const save = (file: string, saved: SavedTable[]) => {
    files.set(file, saved);
    backend.save(file, saved.length ? { v: 1, tables: saved } : null);
  };
  return {
    get(index, header) {
      const file = path();
      if (!file) return null;
      const saved = tables(file);
      const exact = saved.find((table) => table.i === index && table.h === header);
      if (exact) return exact.w;
      // A table added or removed above moves the others: the one saved table with this header.
      const moved = saved.filter((table) => table.h === header);
      return moved.length === 1 ? moved[0]!.w : null;
    },
    set(index, header, widths, live) {
      const file = path();
      if (!file) return;
      // Each saved table stays where its header is now (moved when it is the one table with that
      // header), and a header no table has any more is dropped.
      const kept: SavedTable[] = [];
      for (const table of tables(file)) {
        let at = table.i;
        if (live[at] !== table.h) {
          const first = live.indexOf(table.h);
          at = first >= 0 && live.lastIndexOf(table.h) === first ? first : -1;
        }
        if (at >= 0 && at !== index && !kept.some((other) => other.i === at)) kept.push({ ...table, i: at });
      }
      if (widths) kept.push({ i: index, h: header, w: widths.slice(0, MAX_COLUMNS).map((width) => Math.round(width)) });
      save(file, kept.sort((a, b) => a.i - b.i).slice(0, MAX_TABLES));
    },
    clear() {
      const file = path();
      if (!file) return;
      save(file, []);
      for (const listener of listeners) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

/** The storage the page-only fallback keeps widths in (localStorage; a stand-in in tests). */
export interface WidthStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function localStore(): WidthStorage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * Widths kept in the page's own storage, per file path: the dev page and an older host with no
 * `setTableWidths`. In the app the page's storage does not outlive the tab (its WebKit data store
 * is not persistent), so the app keeps them with the file (`hostTableWidths`).
 */
export function storedTableWidths(
  path: () => string | undefined,
  storage: WidthStorage | null = localStore(),
): TableWidths {
  const key = (file: string) => `cmux.markdown.columnWidths:${file}`;
  return tableWidthsOver(path, {
    load(file) {
      try {
        return parseSavedTableWidths(JSON.parse(storage?.getItem(key(file)) ?? "null"));
      } catch {
        return [];
      }
    },
    save(file, value) {
      try {
        if (value) storage?.setItem(key(file), JSON.stringify(value));
        else storage?.removeItem(key(file));
      } catch {
        // A full or refused storage only loses the widths on the next reopen.
      }
    },
  });
}

/**
 * Widths the host keeps with the file (its extended attribute, then an app-side copy): `initial`
 * answers what the host sent for a file in its config (`tableWidths`), `write` sends one
 * `cmux.markdown.setTableWidths` per change.
 */
export function hostTableWidths(
  path: () => string | undefined,
  initial: (path: string) => unknown,
  write: (path: string, value: SavedTableWidths | null) => void,
): TableWidths {
  return tableWidthsOver(path, { load: (file) => parseSavedTableWidths(initial(file)), save: write });
}

/** Each table view by its `.tableWrapper` (the right-click's Reset Column Widths finds its table). */
const viewsByWrapper = new WeakMap<Element, ResizableTableView>();

/** The table view around `target`, or null. */
export function tableViewAt(target: Element | null): ResizableTableView | null {
  const wrapper = target?.closest?.(".tableWrapper");
  return wrapper ? (viewsByWrapper.get(wrapper) ?? null) : null;
}

/** The narrowest a column can be dragged to, in CSS pixels. */
export const MIN_COLUMN_WIDTH = 40;

/**
 * How close to a column boundary, in pixels either side, the pointer shows that column's line. The
 * handle (the element that carries `cursor: col-resize` and takes the press) covers exactly this
 * zone, so the line, the cursor and the drag always agree (user 2026-10-20: the line showed while
 * the cursor stayed a text cursor).
 */
const EDGE = 5;

/**
 * prosemirror-tables' TableView (the `.tableWrapper` a wide table scrolls sideways in) with
 * column resize handles. Widths come from `TableWidths`, not the document: `colwidth` attrs would
 * be a document change, and GFM cannot write them.
 */
export class ResizableTableView extends TableView {
  private readonly handle: HTMLElement;
  private column = -1;
  private dragging = false;

  constructor(
    node: ProseNode,
    private readonly view: EditorView,
    private readonly getPos: () => number | undefined,
    private readonly widths: TableWidths | undefined,
    cellMinWidth = 100,
  ) {
    super(node, cellMinWidth);
    // A wide table shows that it scrolls by the thin sideways scrollbar, drawn at rest too
    // (scrollers.ts), never by fading its edge (user 2026-10-31: "why blur?"). Set before the box
    // is in the page: WebKit picks a scroller's kind when it makes it.
    this.dom.setAttribute(SIDEWAYS_SCROLLER_ATTRIBUTE, "");
    this.handle = document.createElement("div");
    this.handle.className = "md-col-resize";
    this.handle.contentEditable = "false";
    this.handle.hidden = true;
    this.handle.setAttribute("aria-hidden", "true");
    this.dom.append(this.handle);
    this.dom.addEventListener("mousemove", this.hover);
    this.dom.addEventListener("mouseleave", this.leave);
    this.handle.addEventListener("mousedown", this.startDrag);
    this.handle.addEventListener("dblclick", this.fit);
    this.dom.addEventListener("scroll", this.layoutChanged, { passive: true });
    this.dom.addEventListener("wheel", this.shiftWheel, { passive: false });
    // The box and the table change size with the pane, the text width, an edit and a column drag.
    this.resize = new ResizeObserver(this.layoutChanged);
    this.resize.observe(this.dom);
    this.resize.observe(this.table);
    this.unsubscribe = widths?.subscribe(() => this.applySaved()) ?? (() => {});
    viewsByWrapper.set(this.dom, this);
    this.applySaved();
  }

  private readonly unsubscribe: () => void;

  private readonly resize: ResizeObserver;
  /** Where the pointer last was over the table's box (client coordinates); null once it left. */
  private pointer: { x: number; y: number } | null = null;

  /**
   * A scroll or a size change moved the boundaries under a still pointer: the line follows the
   * pointer (shown only if it is on a boundary now), never stays where the pointer no longer is.
   */
  private readonly layoutChanged = (): void => {
    if (!this.dragging) this.refresh();
  };

  private readonly leave = (): void => {
    this.pointer = null;
    if (!this.dragging) this.hide();
  };

  /**
   * Shift and a vertical wheel scroll a wide table sideways. macOS turns a mouse's Shift-wheel into
   * a horizontal one before the page sees it, but not every engine or device does (WebKit keeps
   * it vertical when the event arrives as deltaY), and then the page scrolled down instead.
   */
  private readonly shiftWheel = (event: WheelEvent): void => {
    if (!event.shiftKey || event.deltaX !== 0 || event.deltaY === 0 || event.ctrlKey || event.metaKey) return;
    const box = this.dom;
    const max = box.scrollWidth - box.clientWidth;
    if (max <= 1) return;
    const step =
      event.deltaMode === WheelEvent.DOM_DELTA_LINE
        ? 16
        : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
          ? box.clientWidth
          : 1;
    event.preventDefault();
    box.scrollLeft = Math.max(0, Math.min(max, box.scrollLeft + event.deltaY * step));
  };

  override update(node: ProseNode): boolean {
    if (!super.update(node)) return false;
    this.applySaved();
    return true;
  }

  /** The header key (`headerKey`) of every table of the document, in order. */
  private liveHeaders(): string[] {
    const headers: string[] = [];
    this.view.state.doc.descendants((node) => {
      if (node.type.name !== "table") return true;
      headers.push(tableHeaderKey(node));
      return false;
    });
    return headers;
  }

  /** Saves (null: forgets) this table's widths: one write, at the end of a drag or a fit. */
  private save(widths: number[] | null): void {
    this.widths?.set(this.index(), tableHeaderKey(this.node), widths, this.liveHeaders());
  }

  /** Forgets this table's widths and lays it out at its natural widths (Reset Column Widths). */
  resetWidths(): void {
    this.layout(null);
    this.save(null);
  }

  /** The table's index among the document's tables (its key in `TableWidths`). */
  private index(): number {
    const pos = this.getPos();
    if (pos === undefined) return -1;
    let index = 0;
    this.view.state.doc.descendants((node, at) => {
      if (at >= pos) return false;
      if (node.type.name === "table") index++;
      return node.type.name !== "table";
    });
    return index;
  }

  private columns(): HTMLTableColElement[] {
    return [...this.colgroup.children] as HTMLTableColElement[];
  }

  private applySaved(): void {
    if (!this.widths || this.view.isDestroyed) return;
    const saved = this.widths.get(this.index(), tableHeaderKey(this.node));
    this.layout(saved && saved.length === this.columns().length ? saved : null);
  }

  /** Fixed widths for every column, or null for the natural (auto) layout. */
  private layout(widths: number[] | null): void {
    const columns = this.columns();
    if (!widths) {
      for (const column of columns) column.style.width = "";
      this.table.style.tableLayout = "";
      this.table.style.width = "";
      this.table.style.minWidth = `${columns.length * this.defaultCellMinWidth}px`;
      return;
    }
    widths.forEach((width, index) => columns[index] && (columns[index].style.width = `${width}px`));
    this.table.style.tableLayout = "fixed";
    this.table.style.width = `${widths.reduce((sum, width) => sum + width, 0)}px`;
    this.table.style.minWidth = "";
  }

  /** Each column's drawn width now (the first row's cells; GFM tables have no spans). */
  private measured(): number[] {
    const row = this.table.querySelector("tr");
    return row ? [...row.children].map((cell) => cell.getBoundingClientRect().width) : [];
  }

  private readonly hover = (event: MouseEvent): void => {
    this.pointer = { x: event.clientX, y: event.clientY };
    if (!this.dragging) this.refresh();
  };

  /** Shows the line of the boundary under the pointer, or hides it. */
  private refresh(): void {
    const hit = this.pointer && this.hit(this.pointer.x, this.pointer.y);
    if (hit) this.place(hit);
    else this.hide();
  }

  /**
   * The zone of each column's right boundary in client x: `EDGE` either side of the line, kept
   * inside the box's visible width and the table's right edge (the last column's handle never
   * sticks out of the scroll box). The one hit test and the one handle geometry use it.
   */
  private zones(): Array<{ column: number; line: number; start: number; end: number }> {
    const row = this.table.querySelector("tr");
    if (!row) return [];
    const box = this.dom.getBoundingClientRect();
    const visibleStart = box.left + this.dom.clientLeft;
    const visibleEnd = visibleStart + (this.dom.clientWidth || box.width);
    const tableEnd = this.table.getBoundingClientRect().right;
    return [...row.children].map((cell, column) => {
      const line = cell.getBoundingClientRect().right;
      const start = Math.max(line - EDGE, visibleStart);
      const end = Math.min(line + EDGE, visibleEnd, tableEnd);
      return { column, line, start, end };
    });
  }

  /** The zone the point is in (the nearest boundary when two overlap), within the table's height. */
  private hit(x: number, y: number): { column: number; line: number; start: number; end: number } | null {
    const table = this.table.getBoundingClientRect();
    if (y < table.top || y >= table.bottom) return null;
    let best: ReturnType<ResizableTableView["zones"]>[number] | null = null;
    for (const zone of this.zones()) {
      if (x < zone.start || x >= zone.end || zone.end <= zone.start) continue;
      if (!best || Math.abs(x - zone.line) < Math.abs(x - best.line)) best = zone;
    }
    return best;
  }

  /** Shows the handle over exactly `zone`, its line on the boundary. */
  private place(zone: { column: number; line: number; start: number; end: number }): void {
    this.column = zone.column;
    const box = this.dom.getBoundingClientRect();
    const table = this.table.getBoundingClientRect();
    const origin = box.left + this.dom.clientLeft - this.dom.scrollLeft;
    this.handle.style.left = `${zone.start - origin}px`;
    this.handle.style.width = `${zone.end - zone.start}px`;
    this.handle.style.marginLeft = "0px";
    this.handle.style.setProperty("--md-col-line", `${zone.line - zone.start}px`);
    this.handle.style.top = `${table.top - box.top - this.dom.clientTop}px`;
    this.handle.style.height = `${table.height}px`;
    this.handle.hidden = false;
  }

  /** Shows the handle on the right boundary of `column` (during a drag and after a fit). */
  private show(column: number): void {
    const zone = this.zones()[column];
    if (zone && zone.end > zone.start) this.place(zone);
    else this.hide();
  }

  private hide(): void {
    this.handle.hidden = true;
    this.column = -1;
  }

  private readonly startDrag = (event: MouseEvent): void => {
    if (event.button !== 0 || this.column < 0 || event.detail > 1) return;
    event.preventDefault();
    event.stopPropagation();
    const column = this.column;
    const start = event.clientX;
    const widths = this.measured();
    const initial = widths[column];
    if (initial === undefined) return;
    this.dragging = true;
    this.dom.classList.add("md-col-resizing");
    const move = (next: MouseEvent) => {
      widths[column] = Math.max(MIN_COLUMN_WIDTH, initial + next.clientX - start);
      this.layout(widths);
      this.show(column);
    };
    const up = (next: MouseEvent) => {
      move(next);
      this.dragging = false;
      this.pointer = { x: next.clientX, y: next.clientY };
      this.dom.classList.remove("md-col-resizing");
      removeEventListener("mousemove", move, true);
      removeEventListener("mouseup", up, true);
      this.save(widths);
    };
    addEventListener("mousemove", move, true);
    addEventListener("mouseup", up, true);
  };

  /** Double-click: the column fits its content (the other columns keep their widths). */
  private readonly fit = (event: MouseEvent): void => {
    event.preventDefault();
    event.stopPropagation();
    const column = this.column;
    if (column < 0) return;
    const saved = this.widths?.get(this.index(), tableHeaderKey(this.node));
    // The natural width: the auto layout's width for this column.
    this.layout(null);
    const natural = this.measured()[column];
    if (saved && natural !== undefined) {
      const widths = saved.map((width, at) => (at === column ? natural : width));
      this.layout(widths);
      this.save(widths);
    }
    this.show(column);
  };

  override ignoreMutation(record: ViewMutationRecord): boolean {
    const target = record.target as Node;
    if (target === this.handle || this.handle.contains(target)) return true;
    if (record.type === "childList" && target === this.dom) return true;
    if (record.type === "attributes" && target === this.dom) return true;
    return super.ignoreMutation(record);
  }

  stopEvent(event: Event): boolean {
    return this.handle.contains(event.target as Node);
  }

  destroy(): void {
    this.dom.removeEventListener("mousemove", this.hover);
    this.dom.removeEventListener("mouseleave", this.leave);
    this.dom.removeEventListener("scroll", this.layoutChanged);
    this.dom.removeEventListener("wheel", this.shiftWheel);
    this.resize.disconnect();
    this.unsubscribe();
  }
}

/** `headerKey` of a table node's first row. */
export function tableHeaderKey(table: ProseNode): string {
  const cells: string[] = [];
  table.firstChild?.forEach((cell) => cells.push(cell.textContent.trim()));
  return headerKey(cells);
}

/** The cell (table_cell or table_header) around the selection's head, with its position. */
function cellAround(state: EditorState): { node: ProseNode; pos: number } | null {
  const { $head } = state.selection;
  for (let depth = $head.depth; depth > 0; depth--) {
    const role = $head.node(depth).type.spec.tableRole;
    if (role === "cell" || role === "header_cell") return { node: $head.node(depth), pos: $head.before(depth) };
  }
  return null;
}

/** Adds an empty body row after row `row` (columns keep their alignment); returns the new row's index. */
function addRowAfter(state: EditorState, schema: Schema, row: number) {
  const table = findTable(state.selection.$head);
  if (!table) return null;
  const map = TableMap.get(table.node);
  const cells = Array.from({ length: map.width }, (_, column) =>
    schema.nodes.table_cell!.createAndFill({
      alignment: table.node.nodeAt(map.map[column]!)?.attrs.alignment ?? "left",
    })!,
  );
  let pos = table.start;
  for (let index = 0; index <= row; index++) pos += table.node.child(index).nodeSize;
  const tr = state.tr.insert(pos, schema.nodes.table_row!.create(null, cells));
  tr.setSelection(TextSelection.near(tr.doc.resolve(pos + 2)));
  return tr.scrollIntoView();
}

/** The caret at the start of cell (`row`, `column`) of the table around the selection. */
function caretInCell(state: EditorState, row: number, column: number) {
  const table = findTable(state.selection.$head);
  if (!table) return null;
  const map = TableMap.get(table.node);
  const cell = map.map[row * map.width + column];
  if (cell === undefined) return null;
  return state.tr.setSelection(TextSelection.near(state.doc.resolve(table.start + cell + 1))).scrollIntoView();
}

/** Obsidian's table keys. Returns true when it handled the key. */
export function tableKeyDown(view: EditorView, event: KeyboardEvent, schema: Schema | null): boolean {
  const { state } = view;
  const plain = !event.altKey && !event.ctrlKey && !event.metaKey;
  if (event.key === "Escape" && state.selection instanceof CellSelection) {
    view.dispatch(state.tr.setSelection(TextSelection.near(state.selection.$headCell, 1)));
    return true;
  }
  if (!isInTable(state) || !schema) return false;

  if (event.key === "a" && event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey) {
    if (state.selection instanceof CellSelection) {
      const rect = selectedRect(state);
      if (!(rect.left === 0 && rect.top === 0 && rect.right === rect.map.width && rect.bottom === rect.map.height))
        return selectTable(view);
      // The whole table is selected: Cmd-A goes on to the whole document. Selected here, not left
      // to the base keymap's Mod-a: that binding is Ctrl-A wherever navigator.platform is not a Mac.
      view.dispatch(state.tr.setSelection(new AllSelection(state.doc)));
      return true;
    }
    const cell = cellAround(state);
    if (!cell) return false;
    const from = cell.pos + 2;
    const to = cell.pos + cell.node.nodeSize - 2;
    if (state.selection.from === from && state.selection.to === to) return selectTable(view);
    view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, from, to)));
    return true;
  }

  if (event.key === "Enter" && plain && !event.shiftKey) {
    if (state.selection instanceof CellSelection) return false;
    const rect = selectedRect(state);
    const tr =
      rect.top + 1 < rect.map.height
        ? caretInCell(state, rect.top + 1, rect.left)
        : addRowAfter(state, schema, rect.top);
    if (tr) view.dispatch(tr);
    return true;
  }

  if (event.key === "Tab" && plain) {
    const direction = event.shiftKey ? -1 : 1;
    if (goToNextCell(direction)(state, view.dispatch)) return true;
    if (direction === 1) {
      const rect = selectedRect(state);
      const tr = addRowAfter(state, schema, rect.map.height - 1);
      if (tr) view.dispatch(tr);
    }
    // Tab never moves the focus out of the document while the caret is in a table.
    return true;
  }
  return false;
}

function selectTable(view: EditorView): boolean {
  const table = findTable(view.state.selection.$head);
  if (!table) return false;
  const map = TableMap.get(table.node);
  const first = view.state.doc.resolve(table.start + map.map[0]!);
  const last = view.state.doc.resolve(table.start + map.map[map.map.length - 1]!);
  view.dispatch(view.state.tr.setSelection(new CellSelection(first, last)));
  return true;
}

/** The selected cells as rows of cells, with each column's alignment. */
function selectedGrid(state: EditorState): { rows: ProseNode[][]; alignments: string[] } | null {
  if (!(state.selection instanceof CellSelection)) return null;
  const rect = selectedRect(state);
  const rows: ProseNode[][] = [];
  for (let row = rect.top; row < rect.bottom; row++) {
    const cells: ProseNode[] = [];
    for (let column = rect.left; column < rect.right; column++) {
      const cell = rect.table.nodeAt(rect.map.map[row * rect.map.width + column]!);
      if (cell) cells.push(cell);
    }
    rows.push(cells);
  }
  const alignments: string[] = [];
  for (let column = rect.left; column < rect.right; column++)
    alignments.push(String(rect.table.nodeAt(rect.map.map[column]!)?.attrs.alignment ?? "left"));
  return { rows, alignments };
}

const DELIMITER: Record<string, string> = { left: "---", center: ":---:", right: "---:" };

/**
 * A cell selection as a Markdown table: the first selected row is the header, each cell's text
 * is its inline Markdown (`inline`) with `|` escaped.
 */
export function cellSelectionMarkdown(state: EditorState, inline: (cell: ProseNode) => string): string | null {
  const grid = selectedGrid(state);
  if (!grid || grid.rows.length === 0) return null;
  const line = (cells: string[]) => `| ${cells.join(" | ")} |`;
  const text = (cell: ProseNode) =>
    inline(cell)
      .replace(/\n+/g, " ")
      .replace(/(?<!\\)\|/g, "\\|")
      .trim();
  const [header, ...body] = grid.rows;
  return [
    line(header!.map(text)),
    line(grid.alignments.map((alignment) => DELIMITER[alignment] ?? "---")),
    ...body.map((row) => line(row.map(text))),
  ].join("\n");
}

/** A cell selection as an HTML table (for spreadsheets and rich paste targets). */
export function cellSelectionHTML(state: EditorState): string | null {
  const grid = selectedGrid(state);
  if (!grid) return null;
  const escape = (value: string) =>
    value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const rows = grid.rows.map(
    (row, index) =>
      `<tr>${row.map((cell) => (index === 0 ? `<th>${escape(cell.textContent)}</th>` : `<td>${escape(cell.textContent)}</td>`)).join("")}</tr>`,
  );
  return `<table>${rows.join("")}</table>`;
}

/** Copy and cut of a cell selection: a Markdown table and an HTML table. Returns true when handled. */
export function tableClipboard(
  view: EditorView,
  event: ClipboardEvent,
  inline: (cell: ProseNode) => string,
  readOnly: boolean,
): boolean {
  const markdown = cellSelectionMarkdown(view.state, inline);
  if (markdown === null || !event.clipboardData) return false;
  event.preventDefault();
  event.clipboardData.clearData();
  event.clipboardData.setData("text/plain", markdown);
  event.clipboardData.setData("text/html", cellSelectionHTML(view.state) ?? "");
  if (event.type === "cut" && !readOnly) {
    // Cut empties the cells and keeps the table's shape, as Obsidian does.
    const { state } = view;
    const tr = state.tr;
    (state.selection as CellSelection).forEachCell((cell, pos) => {
      const from = tr.mapping.map(pos + 1);
      const to = tr.mapping.map(pos + cell.nodeSize - 1);
      tr.replaceWith(from, to, state.schema.nodes.paragraph!.create());
    });
    view.dispatch(tr);
  }
  return true;
}

/**
 * A drag from a cell out of its table selects text from the press to the pointer, as a drag
 * between paragraphs does. Inside the table, prosemirror-tables' cell selection stays.
 */
export const tableDragOutPlugin = $prose(
  () =>
    new Plugin({
      props: {
        handleDOMEvents: {
          mousedown(view, event) {
            if (event.button !== 0 || event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return false;
            if (!(event.target as Element | null)?.closest?.("td, th")) return false;
            const press = view.posAtCoords({ left: event.clientX, top: event.clientY });
            const table = press ? findTable(view.state.doc.resolve(press.pos)) : null;
            if (!press || !table) return false;
            const anchor = press.pos;
            const tablePos = table.pos;
            const window = view.dom.ownerDocument.defaultView;
            if (!window) return false;
            const move = (moved: MouseEvent) => {
              if (moved.buttons === 0 || view.isDestroyed) return stop();
              const hit = view.posAtCoords({ left: moved.clientX, top: moved.clientY });
              if (!hit) return;
              const { doc } = view.state;
              const $head = doc.resolve(hit.pos);
              if (findTable($head)?.pos === tablePos) return;
              const selection = TextSelection.between(doc.resolve(Math.min(anchor, doc.content.size)), $head);
              if (!selection.eq(view.state.selection)) view.dispatch(view.state.tr.setSelection(selection));
            };
            const stop = () => {
              window.removeEventListener("mousemove", move);
              window.removeEventListener("mouseup", stop);
            };
            window.addEventListener("mousemove", move);
            window.addEventListener("mouseup", stop);
            return false;
          },
        },
      },
    }),
);

/** The position before the table cell that holds `$pos`, or -1 outside a cell. */
function cellBefore($pos: ResolvedPos): number {
  for (let depth = $pos.depth; depth > 0; depth--) {
    const role = $pos.node(depth).type.spec.tableRole;
    if (role === "cell" || role === "header_cell") return $pos.before(depth);
  }
  return -1;
}

/**
 * Whether `next` is prosemirror-tables' normalization of `selection`, a text selection from one
 * cell into another: its from cell's text (a head at the next cell's start) or a caret at its from
 * (a selection between two cells' edges). tableEditing's appendTransaction makes it.
 */
function normalizesAcrossCells(selection: Selection, next: Selection): boolean {
  if (!(selection instanceof TextSelection) || !(next instanceof TextSelection)) return false;
  const from = cellBefore(selection.$from);
  if (from < 0 || from === cellBefore(selection.$to)) return false;
  return (
    (next.from === selection.$from.start() && next.to === selection.$from.end()) ||
    (next.empty && next.from === selection.from)
  );
}

/**
 * Pointer selection in tables is text selection (user 2026-10-28). prosemirror-tables turns a drag
 * that crosses into another cell, and a Shift-click from a caret into another cell, into a cell
 * selection; both start with a transaction that sets `tableEditingKey` to the anchor cell. This
 * plugin drops that start unless a cell selection already exists (Cmd-A, then Shift-click extends
 * it), so the browser's own drag selection goes on, and it does the Shift-click itself as a text
 * selection from the anchor to the click.
 *
 * While the button is down it also drops prosemirror-tables' normalization of the drag's text
 * selection: when the pointer crosses a cell's edge, the head lands at the next cell's start, and
 * tableEditing cuts the selection to the first cell's text (or a caret). Chromium waits for the
 * mouseup to write the editor's selection back to the page; WebKit, which the app draws in, writes
 * it at once, and its drag then stayed on the first cell ("Ada" for a drag from Ada to Navy).
 */
export const tableTextSelectPlugin = $prose(() => {
  // Whether the primary button went down in a cell of this editor and is still down; `release`
  // ends it. A press can end without a mouseup reaching the page (released over another app or
  // after a switch away), so the window's blur and a move with the button up end it too, as does
  // the editor's destroy: a stuck flag would drop a keyboard caret move out of a cross-cell
  // selection. A key does not: Shift or Cmd pressed mid-drag leaves the button down.
  let dragging = false;
  let release: (() => void) | undefined;
  return new Plugin({
    view: () => ({ destroy: () => release?.() }),
    filterTransaction(tr, state) {
      if (
        dragging &&
        tr.steps.length === 0 &&
        tr.selectionSet &&
        tr.getMeta("pointer") !== true &&
        normalizesAcrossCells(state.selection, tr.selection)
      )
        return false;
      const anchor = tr.getMeta(tableEditingKey) as number | undefined;
      if (typeof anchor !== "number" || anchor < 0) return true;
      return !(tr.selection instanceof CellSelection) || state.selection instanceof CellSelection;
    },
    props: {
      handleDOMEvents: {
        mousedown(view, event) {
          if (event.button !== 0 || event.metaKey || event.ctrlKey || event.altKey) return false;
          if (!(event.target as Element | null)?.closest?.("td, th")) return false;
          if (!event.shiftKey) {
            const window = view.dom.ownerDocument.defaultView;
            if (!window) return false;
            release?.();
            dragging = true;
            const ends = ["mouseup", "dragstart"] as const;
            const moved = (move: MouseEvent) => {
              if ((move.buttons & 1) === 0) stop();
            };
            const stop = () => {
              dragging = false;
              release = undefined;
              for (const type of ends) window.removeEventListener(type, stop, true);
              window.removeEventListener("mousemove", moved, true);
              window.removeEventListener("blur", stop);
            };
            for (const type of ends) window.addEventListener(type, stop, true);
            window.addEventListener("mousemove", moved, true);
            // Not capturing: the press itself moves focus into the editor, and that element's blur
            // reaches a capturing window listener. Only the window's own blur ends the press.
            window.addEventListener("blur", stop);
            release = stop;
            return false;
          }
          const { state } = view;
          if (state.selection instanceof CellSelection) return false;
          const hit = view.posAtCoords({ left: event.clientX, top: event.clientY });
          if (!hit) return false;
          const selection = TextSelection.between(state.selection.$anchor, state.doc.resolve(hit.pos));
          event.preventDefault();
          if (!selection.eq(state.selection)) view.dispatch(state.tr.setSelection(selection));
          return true;
        },
      },
    },
  });
});
