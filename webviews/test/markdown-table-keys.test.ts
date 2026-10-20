// Obsidian's table keys and copy in the markdown editor (MARKDOWN-OBSIDIAN-PARITY, user 2026-10-19:
// "Highlighting the table in Markdown is very buggy ... we need to have parity with Obsidian").
//
// The real editor (Milkdown over ProseMirror) on a jsdom page: Return goes to the cell below and
// adds a row under the last one (before, it left the table and added a paragraph after it), Tab
// past the last cell adds a row, Cmd-A selects the cell's text and then the whole table, Escape
// drops a cell selection, and copying cells writes a Markdown table and an HTML table. Column
// widths are a view setting: they never change the markdown a save writes.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { TextSelection } from "@milkdown/kit/prose/state";
import { CellSelection } from "@milkdown/kit/prose/tables";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";
import type { TableWidths } from "../src/pages/markdown/tables";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;
let storedTableWidths: typeof import("../src/pages/markdown/tables").storedTableWidths;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
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
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  ({ MarkdownEditor } = await import("../src/pages/markdown/editor"));
  ({ storedTableWidths } = await import("../src/pages/markdown/tables"));
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
    (selection as CellSelection).forEachCell(() => cells++);
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
    widths.set(0, [120.4, 80]);
    expect(widths.get(0)).toEqual([120, 80]);
    path = "/w/b.md";
    expect(widths.get(0)).toBe(null);
    path = "/w/a.md";
    const md = await setup(TABLE, widths);
    const cols = [...md.view().dom.querySelectorAll("colgroup col")] as HTMLElement[];
    expect(cols.map((col) => col.style.width)).toEqual(["120px", "80px"]);
    expect(md.markdown()).toBe(TABLE);
    widths.set(0, null);
    expect(values.size).toBe(0);
  });
});
