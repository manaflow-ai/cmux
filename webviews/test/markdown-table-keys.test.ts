// Obsidian's table keys and copy in the markdown editor (MARKDOWN-OBSIDIAN-PARITY, user 2026-10-19:
// "Highlighting the table in Markdown is very buggy ... we need to have parity with Obsidian").
//
// The real editor (Milkdown over ProseMirror) on a jsdom page: Return goes to the cell below and
// adds a row under the last one (before, it left the table and added a paragraph after it), Tab
// past the last cell adds a row, Cmd-A selects the cell's text and then the whole table, Escape
// drops a cell selection, and copying cells writes a Markdown table and an HTML table. Column
// widths are a view setting: they never change the markdown a save writes.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";
import type { TableWidths } from "../src/pages/markdown/tables";

let dom: JSDOM;
// ProseMirror loaded after the page says it is a Mac (beforeAll): see there.
let TextSelection: typeof import("@milkdown/kit/prose/state").TextSelection;
let CellSelection: typeof import("@milkdown/kit/prose/tables").CellSelection;
let MarkdownEditor: typeof Editor;
let storedTableWidths: typeof import("../src/pages/markdown/tables").storedTableWidths;
let headerKey: typeof import("../src/pages/markdown/tables").headerKey;
let widthTables: typeof import("../src/pages/markdown/tables");

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  // The editor runs in a Mac WebView, where ProseMirror's Mod is Cmd: its keymaps read
  // navigator.platform once, when they load. jsdom's platform is "", and bun's is the host's,
  // so on a Linux runner Mod was Ctrl and the third Cmd-A below never reached Select All.
  // This holds only when this file has its own process (scripts/ci/run-webviews-tests.sh):
  // ProseMirror decides once per process, so after another editor test (markdown-selection,
  // markdown-link-bubble) loaded it in the same `bun test`, the override comes too late.
  Object.defineProperty(dom.window.navigator, "platform", { value: "MacIntel", configurable: true });
  const scope = globalThis as Record<string, unknown>;
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "Element",
    "getComputedStyle",
    "MutationObserver",
    "DOMParser",
    "Text",
    "requestAnimationFrame",
    "KeyboardEvent",
    "MouseEvent",
    "Event",
  ])
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  // jsdom has no ResizeObserver; the table view only uses it to mark overflowing edges.
  scope.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  ({ TextSelection } = await import("@milkdown/kit/prose/state"));
  ({ CellSelection } = await import("@milkdown/kit/prose/tables"));
  ({ MarkdownEditor } = await import("../src/pages/markdown/editor"));
  widthTables = await import("../src/pages/markdown/tables");
  ({ storedTableWidths, headerKey } = widthTables);
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
});

const TABLE = `| Name | Role |
| --- | :---: |
| Ada | **Engineer** |
| Grace | Admiral |
`;

async function setup(text: string, tableWidths?: TableWidths) {
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: { openLink: () => {}, imageURL: (src) => src, label: (key) => key, tableWidths },
  });
  editors.push(editor);
  await editor.create();
  editor.load(text);
  const view = () => editor.editorView()!;
  const find = (needle: string) => {
    let found = -1;
    view().state.doc.descendants((node, pos) => {
      if (found >= 0) return false;
      if (node.isText && node.text!.includes(needle)) found = pos + node.text!.indexOf(needle);
      return found < 0;
    });
    if (found < 0) throw new Error(`no "${needle}" in the document`);
    return found;
  };
  /** Sends a key down the editor's own key handling (the view's handleKeyDown props). */
  const key = (name: string, modifiers: { shift?: boolean; meta?: boolean } = {}) => {
    const event = new dom.window.KeyboardEvent("keydown", {
      key: name,
      shiftKey: modifiers.shift ?? false,
      metaKey: modifiers.meta ?? false,
      bubbles: true,
      cancelable: true,
    });
    view().dom.dispatchEvent(event);
    return event.defaultPrevented;
  };
  return {
    editor,
    view,
    markdown: () => editor.snapshot().text,
    caret(needle: string, offset = 0) {
      const at = find(needle) + offset;
      editor.focus();
      view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, at)));
    },
    key,
    selectedText: () => {
      const { state } = view();
      return state.doc.textBetween(state.selection.from, state.selection.to, "|");
    },
    type(value: string) {
      const v = view();
      v.dispatch(v.state.tr.insertText(value));
    },
  };
}

/** The text of the cell holding the caret. */
const caretCell = (md: Awaited<ReturnType<typeof setup>>) => md.view().state.selection.$head.parent.textContent;

describe("markdown table keys", () => {
  test("Return goes to the cell below and stays in the table", async () => {
    const md = await setup(TABLE);
    md.caret("Ada", 1);
    expect(md.key("Enter")).toBe(true);
    expect(caretCell(md)).toBe("Grace");
    expect(md.markdown()).toBe(TABLE);
  });

  test("Return in the last row adds a row below, keeping the columns' alignment", async () => {
    const md = await setup(TABLE);
    md.caret("Admiral", 2);
    md.key("Enter");
    md.type("Linus");
    expect(md.markdown()).toMatch(/\| Linus +\|/);
    expect(md.markdown()).not.toContain("\n\nLinus");
    expect(md.markdown().trimEnd().split("\n")).toHaveLength(5);
  });

  test("Tab moves on a cell and adds a row past the last cell; Shift-Tab goes back", async () => {
    const md = await setup(TABLE);
    md.caret("Ada", 0);
    md.key("Tab");
    expect(caretCell(md)).toBe("Engineer");
    md.key("Tab", { shift: true });
    expect(caretCell(md)).toBe("Ada");
    md.caret("Admiral", 0);
    expect(md.key("Tab")).toBe(true);
    md.type("new");
    expect(md.markdown().trimEnd().split("\n")).toHaveLength(5);
    // An edited table is written with its columns padded (the serializer's GFM table spelling).
    expect(md.markdown()).toMatch(/\| new +\|/);
  });

  test("Cmd-A selects the cell's text, then the whole table, then lets the document take it", async () => {
    const md = await setup(`Before.\n\n${TABLE}`);
    md.caret("Grace", 2);
    expect(md.key("a", { meta: true })).toBe(true);
    expect(md.selectedText()).toBe("Grace");
    expect(md.key("a", { meta: true })).toBe(true);
    const selection = md.view().state.selection;
    expect(selection instanceof CellSelection).toBe(true);
    let cells = 0;
    (selection as InstanceType<typeof CellSelection>).forEachCell(() => cells++);
    expect(cells).toBe(6);
    // The third Cmd-A is the editor's own Select All: the whole document.
    md.key("a", { meta: true });
    const all = md.view().state.selection;
    expect(all instanceof CellSelection).toBe(false);
    expect([all.from, all.to]).toEqual([0, md.view().state.doc.content.size]);
  });

  test("Escape drops a cell selection to a caret", async () => {
    const md = await setup(TABLE);
    md.caret("Ada", 0);
    md.key("a", { meta: true });
    md.key("a", { meta: true });
    expect(md.view().state.selection instanceof CellSelection).toBe(true);
    expect(md.key("Escape")).toBe(true);
    expect(md.view().state.selection instanceof CellSelection).toBe(false);
  });

  test("copying cells writes a Markdown table and an HTML table", async () => {
    const md = await setup(TABLE);
    md.caret("Ada", 0);
    md.key("a", { meta: true });
    md.key("a", { meta: true });
    const data = new Map<string, string>();
    const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
      clipboardData: unknown;
    };
    event.clipboardData = {
      setData: (type: string, value: string) => data.set(type, value),
      clearData: () => data.clear(),
      getData: (type: string) => data.get(type) ?? "",
    };
    md.view().dom.dispatchEvent(event);
    expect(data.get("text/plain")).toBe(
      "| Name | Role |\n| --- | :---: |\n| Ada | **Engineer** |\n| Grace | Admiral |",
    );
    expect(data.get("text/html")).toContain("<th>Name</th>");
    expect(data.get("text/html")).toContain("<td>Engineer</td>");
  });

  test("column widths are kept per file and never touch the markdown", async () => {
    const values = new Map<string, string>();
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => void values.set(key, value),
      removeItem: (key: string) => void values.delete(key),
    };
    let path = "/w/a.md";
    const widths = storedTableWidths(() => path, storage);
    const header = headerKey(["Name", "Role"]);
    widths.set(0, header, [120.4, 80], [header]);
    expect(widths.get(0, header)).toEqual([120, 80]);
    path = "/w/b.md";
    expect(widths.get(0, header)).toBe(null);
    path = "/w/a.md";
    const md = await setup(TABLE, widths);
    const cols = [...md.view().dom.querySelectorAll("colgroup col")] as HTMLElement[];
    expect(cols.map((col) => col.style.width)).toEqual(["120px", "80px"]);
    expect(md.markdown()).toBe(TABLE);
    widths.set(0, header, null, [header]);
    expect(values.size).toBe(0);
  });
});

// Table column widths outlive the tab (user 2026-10-20: "i close tab and reopen it and the custom
// widths i set are gone"; plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md). The page's own storage
// dies with the tab in the app (its WebKit data store is not persistent), so the host keeps the
// widths with the file. A Map stands in for the host: each "tab" is a fresh editor and a fresh
// `hostTableWidths` that only sees what the host sent back in its config. A drag writes once, when
// it ends; a changed header drops its widths; a table added above keeps the others' widths; Reset
// Column Widths forgets one table or every table.
const widthEditors: Editor[] = [];
const PATH = "/w/notes.md";
/** Every cell's drawn width. */
const CELL = 100;
const PLAIN_TABLE = `| Name | Role |
| --- | --- |
| Ada | Engineer |
`;
const OTHER = `| City | Country |
| --- | --- |
| Oslo | Norway |
`;

/** The host: what it keeps per file (the file's attribute), and every write the page sent. */
function fakeHost() {
  const kept = new Map<string, unknown>();
  const writes: Array<{ path: string; value: unknown }> = [];
  return {
    kept,
    writes,
    /** A new tab on `path`: a fresh page store seeded only from the host's config. */
    tab(path = PATH) {
      return widthTables.hostTableWidths(
        () => path,
        (file) => kept.get(file),
        (file, value) => {
          writes.push({ path: file, value });
          if (value) kept.set(file, JSON.parse(JSON.stringify(value)));
          else kept.delete(file);
        },
      );
    },
  };
}

async function openWithWidths(text: string, widths: TableWidths) {
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: { openLink: () => {}, imageURL: (src) => src, label: (key) => key, tableWidths: widths },
  });
  editors.push(editor);
  await editor.create();
  editor.load(text);
  const view = editor.editorView()!;
  const columns = (table = 0) =>
    ([...view.dom.querySelectorAll(".tableWrapper")[table]!.querySelectorAll("colgroup col")] as HTMLElement[]).map(
      (col) => col.style.width,
    );
  /** Drags the right edge of `column` of the first table by `dx` pixels in `steps` moves. */
  const drag = (column: number, dx: number, steps: number) => {
    // The drag listens on the page's window (widthTables.ts startDrag): the jsdom window, for the drag.
    const scope = globalThis as Record<string, unknown>;
    const saved = [scope.addEventListener, scope.removeEventListener];
    scope.addEventListener = dom.window.addEventListener.bind(dom.window);
    scope.removeEventListener = dom.window.removeEventListener.bind(dom.window);
    const wrapper = view.dom.querySelector(".tableWrapper")!;
    const cell = wrapper.querySelectorAll("tr")[0]!.children[column]!;
    const edge = (column + 1) * CELL - 2;
    cell.dispatchEvent(new dom.window.MouseEvent("mousemove", { bubbles: true, clientX: edge, clientY: 5 }));
    const handle = wrapper.querySelector(".md-col-resize")!;
    handle.dispatchEvent(
      new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1, clientX: edge, clientY: 5 }),
    );
    for (let step = 1; step <= steps; step++) {
      dom.window.dispatchEvent(
        new dom.window.MouseEvent("mousemove", { clientX: edge + (dx * step) / steps, clientY: 5 }),
      );
    }
    dom.window.dispatchEvent(new dom.window.MouseEvent("mouseup", { clientX: edge + dx, clientY: 5 }));
    [scope.addEventListener, scope.removeEventListener] = saved;
  };
  return { editor, view, columns, drag, markdown: () => editor.snapshot().text };
}

describe("markdown table width memory", () => {
  // Each cell draws 100px wide (jsdom lays nothing out), so a drag has a width to start from.
  let boxed: unknown;
  beforeAll(() => {
    const prototype = dom.window.Element.prototype as unknown as Record<string, unknown>;
    boxed = prototype.getBoundingClientRect;
    // Column c spans [c*100, (c+1)*100), rows 30px; the table and its box are as wide as the columns.
    const rect = (left: number, top: number, width: number, height: number) => ({
      left,
      top,
      right: left + width,
      bottom: top + height,
      width,
      height,
      x: left,
      y: top,
      toJSON: () => ({}),
    });
    prototype.getBoundingClientRect = function (this: Element) {
      if (this.tagName === "TD" || this.tagName === "TH") {
        const cell = this as HTMLTableCellElement;
        return rect(cell.cellIndex * CELL, (cell.parentElement as HTMLTableRowElement).rowIndex * 30, CELL, 30);
      }
      if (this.tagName === "TABLE" || this.classList.contains("tableWrapper")) {
        const columns = this.querySelector("tr")?.children.length ?? 0;
        return rect(0, 0, columns * CELL, (this.querySelectorAll("tr").length || 1) * 30);
      }
      return rect(0, 0, 0, 0);
    };
  });
  afterAll(() => {
    (dom.window.Element.prototype as unknown as Record<string, unknown>).getBoundingClientRect = boxed;
  });
  afterEach(async () => {
    for (const editor of widthEditors.splice(0)) await editor.destroy();
  });

  test("a column drag writes once, when it ends, and a reopened tab lays the table out at those widths", async () => {
    const host = fakeHost();
    const first = await openWithWidths(PLAIN_TABLE, host.tab());
    // Each move resizes the column on screen; nothing reaches the host until the drag ends.
    first.drag(0, 150, 8);
    expect(host.writes.length).toBe(1);
    expect(first.columns()).toEqual(["250px", "100px"]);
    expect(first.markdown()).toBe(PLAIN_TABLE);
    await first.editor.destroy();

    // Closed and reopened: a new page, seeded only from the host's config.
    const again = await openWithWidths(PLAIN_TABLE, host.tab());
    expect(again.columns()).toEqual(["250px", "100px"]);
    expect(host.writes.length).toBe(1);
  });

  test("an edit elsewhere keeps the widths, a changed header drops them", async () => {
    const host = fakeHost();
    const first = await openWithWidths(PLAIN_TABLE, host.tab());
    first.drag(1, 200, 3);
    expect(first.columns()).toEqual(["100px", "300px"]);

    const edited = await openWithWidths(`# Title\n\nSome text.\n\n${PLAIN_TABLE}`, host.tab());
    expect(edited.columns()).toEqual(["100px", "300px"]);

    const renamed = await openWithWidths(PLAIN_TABLE.replace("Role", "Title"), host.tab());
    expect(renamed.columns()).toEqual(["", ""]);
    // The next write drops the stale table.
    renamed.drag(0, 90, 2);
    const saved = widthTables.parseSavedTableWidths(host.kept.get(PATH));
    expect(saved).toEqual([{ i: 0, h: widthTables.headerKey(["Name", "Title"]), w: [190, 100] }]);
  });

  test("a table added above keeps the widths with their table", async () => {
    const host = fakeHost();
    const first = await openWithWidths(PLAIN_TABLE, host.tab());
    first.drag(0, 120, 2);
    const moved = await openWithWidths(`${OTHER}\n${PLAIN_TABLE}`, host.tab());
    expect(moved.columns(0)).toEqual(["", ""]);
    expect(moved.columns(1)).toEqual(["220px", "100px"]);
  });

  test("each file keeps its own widths", async () => {
    const host = fakeHost();
    const first = await openWithWidths(PLAIN_TABLE, host.tab("/w/a.md"));
    first.drag(0, 120, 2);
    const other = await openWithWidths(PLAIN_TABLE, host.tab("/w/b.md"));
    expect(other.columns()).toEqual(["", ""]);
  });

  test("Reset Column Widths forgets the right-clicked table, the action every table", async () => {
    const host = fakeHost();
    const widths = host.tab();
    const md = await openWithWidths(`${PLAIN_TABLE}\n${OTHER}`, widths);
    const wrappers = md.view.dom.querySelectorAll(".tableWrapper");
    md.drag(0, 120, 2);
    // Widths for the second table too, as a reopened file would have them.
    widths.set(
      1,
      widthTables.headerKey(["City", "Country"]),
      [70, 90],
      [widthTables.headerKey(["Name", "Role"]), widthTables.headerKey(["City", "Country"])],
    );
    const reopened = await openWithWidths(`${PLAIN_TABLE}\n${OTHER}`, host.tab());
    expect(reopened.columns(1)).toEqual(["70px", "90px"]);

    const cell = reopened.view.dom.querySelectorAll(".tableWrapper")[1]!.querySelector("td")!;
    expect(reopened.editor.tableIndexAt(cell)).toBe(1);
    expect(reopened.editor.resetTableWidthsAt(cell)).toBe(true);
    expect(reopened.columns(1)).toEqual(["", ""]);
    expect(reopened.columns(0)).toEqual(["220px", "100px"]);
    expect(widthTables.parseSavedTableWidths(host.kept.get(PATH)).map((table) => table.i)).toEqual([0]);
    expect(reopened.editor.resetTableWidthsAt(reopened.view.dom)).toBe(false);

    reopened.editor.resetTableWidths();
    expect(reopened.columns(0)).toEqual(["", ""]);
    expect(host.kept.has(PATH)).toBe(false);
    expect(host.writes.at(-1)).toEqual({ path: PATH, value: null });
    expect(wrappers.length).toBe(2);
  });

  test("a malformed saved value counts as none", () => {
    expect(widthTables.parseSavedTableWidths({ v: 2, tables: [] })).toEqual([]);
    expect(widthTables.parseSavedTableWidths({ v: 1, tables: [{ i: 0, h: "x", w: [0] }] })).toEqual([]);
    expect(widthTables.parseSavedTableWidths("nope")).toEqual([]);
  });
});

// The column line and the resize cursor show together (user 2026-10-20: hovering a column line
// "sometimes highlights the line but the cursor doesn't change", so it looks draggable but is
// not). The cursor comes from the handle element (`cursor: col-resize`), so: wherever the hover
// shows the line, the pointer is over the handle, and wherever it is over the handle, a press
// drags. jsdom lays nothing out, so cells get real rects here: column c spans [c*100, (c+1)*100)
// minus the wrapper's scroll offset, rows 30px each, and the handle's box comes from its inline
// style plus the stylesheet's defaults (width 9px, margin-left -5px) where it sets none.
describe("markdown table resize hover", () => {
  const ROW = 30;
  let scroll = 0;
  let wrapperWidth = 200;
  let boxed: unknown;
  const rect = (left: number, top: number, width: number, height: number) => ({
    left,
    top,
    right: left + width,
    bottom: top + height,
    width,
    height,
    x: left,
    y: top,
    toJSON: () => ({}),
  });
  beforeAll(() => {
    const prototype = dom.window.Element.prototype as unknown as Record<string, unknown>;
    boxed = prototype.getBoundingClientRect;
    prototype.getBoundingClientRect = function (this: Element) {
      if (this.tagName === "TD" || this.tagName === "TH") {
        const cell = this as HTMLTableCellElement;
        const row = (cell.parentElement as HTMLTableRowElement).rowIndex;
        return rect(cell.cellIndex * CELL - scroll, row * ROW, CELL, ROW);
      }
      if (this.tagName === "TABLE") return rect(-scroll, 0, 2 * CELL, 3 * ROW);
      if (this.classList.contains("tableWrapper")) return rect(0, 0, wrapperWidth, 3 * ROW);
      return rect(0, 0, 0, 0);
    };
  });
  afterAll(() => {
    (dom.window.Element.prototype as unknown as Record<string, unknown>).getBoundingClientRect = boxed;
  });
  afterEach(async () => {
    scroll = 0;
    wrapperWidth = 200;
    for (const editor of widthEditors.splice(0)) await editor.destroy();
  });

  async function table() {
    const md = await openWithWidths(
      PLAIN_TABLE,
      widthTables.storedTableWidths(() => undefined, null),
    );
    const wrapper = md.view.dom.querySelector(".tableWrapper") as HTMLElement;
    Object.defineProperty(wrapper, "scrollLeft", { configurable: true, get: () => scroll, set: () => {} });
    Object.defineProperty(wrapper, "clientWidth", { configurable: true, get: () => wrapperWidth });
    Object.defineProperty(wrapper, "scrollWidth", { configurable: true, get: () => Math.max(wrapperWidth, 2 * CELL) });
    const handle = wrapper.querySelector(".md-col-resize") as HTMLElement;
    const cells = (row: number) => [...wrapper.querySelectorAll("tr")[row]!.children] as HTMLElement[];
    /** The handle's box in client x (its style, the stylesheet's defaults where it sets none). */
    const handleBox = () => {
      const px = (value: string, fallback: number) => (value ? parseFloat(value) : fallback);
      const left = px(handle.style.left, 0) + px(handle.style.marginLeft, -5) - scroll;
      return { left, right: left + px(handle.style.width, 9) };
    };
    /** Whether the pointer at `x` is over the shown handle (where the col-resize cursor shows). */
    const overHandle = (x: number) => !handle.hidden && x >= handleBox().left && x < handleBox().right;
    /** The element under the pointer at (x, y): the shown handle on top, else the cell, else the wrapper. */
    const under = (x: number, y: number): Element => {
      if (overHandle(x)) return handle;
      const row = Math.floor(y / ROW);
      const column = Math.floor((x + scroll) / CELL);
      return row >= 0 && row < 2 && column >= 0 && column < 2 ? cells(row)[column]! : wrapper;
    };
    const hover = (x: number, y: number) =>
      under(x, y).dispatchEvent(new dom.window.MouseEvent("mousemove", { bubbles: true, clientX: x, clientY: y }));
    return { md, wrapper, handle, cells, handleBox, overHandle, hover, under };
  }

  test("the line shows exactly where the resize cursor does, in the header and in the body", async () => {
    const t = await table();
    const mismatches: string[] = [];
    for (const y of [ROW / 2, ROW + ROW / 2]) {
      for (let x = 80; x <= 120; x += 0.5) {
        t.hover(x, y);
        // The line shows (the handle is not hidden) only with the pointer on the handle.
        if (!t.handle.hidden && !t.overHandle(x)) mismatches.push(`y=${y} x=${x}: line without cursor`);
        // Near the boundary between the two columns, the line shows.
        if (Math.abs(x - CELL) < 3 && t.handle.hidden) mismatches.push(`y=${y} x=${x}: no line at the boundary`);
      }
    }
    expect(mismatches).toEqual([]);
  });

  test("the last column's handle stays inside the table's box", async () => {
    const t = await table();
    for (let x = 190; x < 200; x += 0.5) {
      t.hover(x, ROW / 2);
      if (t.handle.hidden) continue;
      expect(t.overHandle(x)).toBe(true);
      expect(t.handleBox().right).toBeLessThanOrEqual(wrapperWidth);
    }
    t.hover(198, ROW / 2);
    expect(t.handle.hidden).toBe(false);
  });

  test("a press wherever the line shows drags the column", async () => {
    const t = await table();
    const scope = globalThis as Record<string, unknown>;
    const saved = [scope.addEventListener, scope.removeEventListener];
    scope.addEventListener = dom.window.addEventListener.bind(dom.window);
    scope.removeEventListener = dom.window.removeEventListener.bind(dom.window);
    try {
      for (let x = 90; x <= 110; x += 0.5) {
        t.hover(x, ROW / 2);
        if (t.handle.hidden) continue;
        const target = t.under(x, ROW / 2);
        target.dispatchEvent(
          new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1, clientX: x, clientY: 15 }),
        );
        expect([x, t.wrapper.classList.contains("md-col-resizing")]).toEqual([x, true]);
        dom.window.dispatchEvent(new dom.window.MouseEvent("mouseup", { clientX: x, clientY: 15 }));
      }
    } finally {
      [scope.addEventListener, scope.removeEventListener] = saved;
    }
  });

  test("a scrolled wide table: the line follows the pointer, never a stale spot", async () => {
    wrapperWidth = 150;
    const t = await table();
    t.hover(CELL - 1, ROW / 2);
    expect(t.overHandle(CELL - 1)).toBe(true);
    // The table scrolls 30px under a still pointer: the line it showed moved away with it.
    scroll = 30;
    t.wrapper.dispatchEvent(new dom.window.Event("scroll"));
    expect(t.handle.hidden || t.overHandle(CELL - 1)).toBe(true);
    // Over the scrolled boundary (now at x=70), the line and the cursor show together.
    t.hover(CELL - 30 - 1, ROW / 2);
    expect(t.overHandle(CELL - 30 - 1)).toBe(true);
  });

  test("after a resize the new boundary has the line and the cursor", async () => {
    const t = await table();
    t.md.drag(0, 50, 2);
    // The stub keeps 100px cells, so the boundary the hover sees stays at 100: it still lines up.
    t.hover(CELL + 1, ROW + ROW / 2);
    expect(t.handle.hidden).toBe(false);
    expect(t.overHandle(CELL + 1)).toBe(true);
  });
});
