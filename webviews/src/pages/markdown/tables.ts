// Tables in the markdown editor, as Obsidian's (MARKDOWN-OBSIDIAN-PARITY, PARITY.md):
//
// - Keys: Return goes to the cell below and adds a row under the last one, Tab past the last cell
//   adds a row, Cmd-A selects the cell's text and then the whole table, Escape drops a cell
//   selection to a caret.
// - Copying a cell selection writes a Markdown table (text/plain) and an HTML table (text/html, for
//   spreadsheets).
// - Column widths: a handle on each column's right edge; a drag sets the width, a double-click fits
//   the column to its content. Widths are a view setting kept per file (`TableWidths`), never
//   written to the file: GFM has no column widths, and a resize must not mark the file edited.
import type { Node as ProseNode, Schema } from "@milkdown/kit/prose/model";
import { TextSelection, type EditorState } from "@milkdown/kit/prose/state";
import {
  CellSelection,
  TableMap,
  TableView,
  findTable,
  goToNextCell,
  isInTable,
  selectedRect,
} from "@milkdown/kit/prose/tables";
import type { EditorView, ViewMutationRecord } from "@milkdown/kit/prose/view";

/** Column widths, in CSS pixels, for each table of the open file (by its index in the file). */
export interface TableWidths {
  /** The saved widths of table `index`, one per column, or null for the natural widths. */
  get(index: number): number[] | null;
  /** Saves (or with null forgets) the widths of table `index`. */
  set(index: number, widths: number[] | null): void;
}

/** The storage widths survive a reload and a reopen in (localStorage; a stand-in in tests). */
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

/** Widths kept per file path (`path` is read on each call: link navigation changes the file). */
export function storedTableWidths(
  path: () => string | undefined,
  storage: WidthStorage | null = localStore(),
): TableWidths {
  const key = () => {
    const file = path();
    return file ? `cmux.markdown.columnWidths:${file}` : null;
  };
  const read = (): Record<string, number[]> => {
    const name = key();
    if (!name || !storage) return {};
    try {
      const value = JSON.parse(storage.getItem(name) ?? "{}");
      return value && typeof value === "object" ? value : {};
    } catch {
      return {};
    }
  };
  return {
    get(index) {
      const widths = read()[index];
      return Array.isArray(widths) && widths.every((width) => typeof width === "number" && width > 0) ? widths : null;
    },
    set(index, widths) {
      const name = key();
      if (!name || !storage) return;
      const all = read();
      if (widths) all[index] = widths.map((width) => Math.round(width));
      else delete all[index];
      try {
        if (Object.keys(all).length === 0) storage.removeItem(name);
        else storage.setItem(name, JSON.stringify(all));
      } catch {
        // A full or refused storage only loses the widths on the next reload.
      }
    },
  };
}

/** The narrowest a column can be dragged to, in CSS pixels. */
export const MIN_COLUMN_WIDTH = 40;

/** How close to a cell's right edge, in pixels, the pointer shows that column's handle. */
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
    this.handle = document.createElement("div");
    this.handle.className = "md-col-resize";
    this.handle.contentEditable = "false";
    this.handle.hidden = true;
    this.handle.setAttribute("aria-hidden", "true");
    this.dom.append(this.handle);
    this.dom.addEventListener("mousemove", this.hover);
    this.dom.addEventListener("mouseleave", () => {
      if (!this.dragging) this.hide();
    });
    this.handle.addEventListener("mousedown", this.startDrag);
    this.handle.addEventListener("dblclick", this.fit);
    this.applySaved();
  }

  override update(node: ProseNode): boolean {
    if (!super.update(node)) return false;
    this.applySaved();
    return true;
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
    const saved = this.widths.get(this.index());
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
    if (this.dragging || event.target === this.handle) return;
    const cell = (event.target as Element | null)?.closest?.("td, th") as HTMLTableCellElement | null;
    if (!cell || !this.table.contains(cell)) return this.hide();
    const rect = cell.getBoundingClientRect();
    let column = -1;
    if (event.clientX >= rect.right - EDGE) column = cell.cellIndex;
    else if (event.clientX <= rect.left + EDGE && cell.cellIndex > 0) column = cell.cellIndex - 1;
    if (column < 0) return this.hide();
    this.show(column);
  };

  /** Shows the handle on the right edge of `column`. */
  private show(column: number): void {
    const row = this.table.querySelector("tr");
    const cell = row?.children[column] as HTMLElement | undefined;
    if (!cell) return this.hide();
    this.column = column;
    const wrapper = this.dom.getBoundingClientRect();
    const table = this.table.getBoundingClientRect();
    const right = cell.getBoundingClientRect().right;
    this.handle.style.left = `${right - wrapper.left + this.dom.scrollLeft}px`;
    this.handle.style.top = `${table.top - wrapper.top}px`;
    this.handle.style.height = `${table.height}px`;
    this.handle.hidden = false;
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
      this.dom.classList.remove("md-col-resizing");
      removeEventListener("mousemove", move, true);
      removeEventListener("mouseup", up, true);
      this.widths?.set(this.index(), widths);
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
    const index = this.index();
    const saved = this.widths?.get(index);
    // The natural width: the auto layout's width for this column.
    this.layout(null);
    const natural = this.measured()[column];
    if (saved && natural !== undefined) {
      const widths = saved.map((width, at) => (at === column ? natural : width));
      this.layout(widths);
      this.widths?.set(index, widths);
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
  }
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
      // The whole table is selected: Cmd-A goes on to the whole document.
      const rect = selectedRect(state);
      return !(rect.left === 0 && rect.top === 0 && rect.right === rect.map.width && rect.bottom === rect.map.height)
        ? selectTable(view)
        : false;
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
