// Text selection in the markdown editor core (MARKDOWN-SELECTION, user 2026-10-20: "I do highlight
// stuff in Markdown and it's buggy in general"). The real editor (Milkdown over ProseMirror) on a
// jsdom page, fast; test/markdown-selection-drag.test.ts drives the same rules with a real pointer:
//
// - loading the file again (a reload from disk) keeps the selection on the same words and keeps the
//   DOM of every block that did not change (before, the whole document was replaced and the
//   selection fell to its end);
// - Obsidian syntax shows for a caret in it or a selection inside it, not for a selection that only
//   crosses it (before, a drag or Cmd-A revealed every marker it crossed and moved the text);
// - while the primary button is down (a drag), what the selection reveals stays as it was, and the
//   release brings it up to date.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { AllSelection, TextSelection } from "@milkdown/kit/prose/state";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;

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
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
});

const DOC = `# Guide

First paragraph with **bold words** in it.

Second paragraph with ==highlighted words== and more.

- First item
- Second item

Last paragraph ends the guide.
`;

async function setup(text = DOC) {
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: { openLink: () => {}, imageURL: (src) => src, label: (key) => key },
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
  const select = (from: number, to = from) =>
    view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, from, to)));
  return {
    editor,
    view,
    find,
    select,
    /** Selects `needle` (from `offset`, `length` characters; the whole needle by default). */
    selectText(needle: string, offset = 0, length = needle.length - offset) {
      const from = find(needle) + offset;
      select(from, from + length);
    },
    selectedText: () => {
      const { state } = view();
      return state.doc.textBetween(state.selection.from, state.selection.to, "|");
    },
    revealed: () => view().dom.querySelectorAll(".md-syntax").length,
    hidden: () => view().dom.querySelectorAll(".md-syntax-hidden").length,
    /** The DOM element of the top-level block holding `needle`. */
    blockDOM(needle: string) {
      const $pos = view().state.doc.resolve(find(needle));
      return view().nodeDOM($pos.before(1));
    },
    press() {
      view().dom.dispatchEvent(new dom.window.MouseEvent("mousedown", { button: 0, bubbles: true, cancelable: true }));
    },
    release() {
      dom.window.dispatchEvent(new dom.window.MouseEvent("mouseup", { button: 0, bubbles: true }));
    },
  };
}

describe("a reload from disk keeps the selection", () => {
  test("the same text: the selection and every block's DOM stay", async () => {
    const md = await setup();
    md.selectText("Last paragraph");
    const last = md.blockDOM("Last paragraph");
    md.editor.load(DOC);
    expect(md.selectedText()).toBe("Last paragraph");
    expect(md.blockDOM("Last paragraph")).toBe(last);
  });

  test("a change above the selection: the selection stays on its words", async () => {
    const md = await setup();
    md.selectText("Last paragraph");
    const last = md.blockDOM("Last paragraph");
    md.editor.load(DOC.replace("First paragraph with **bold words** in it.", "First paragraph, rewritten elsewhere."));
    expect(md.selectedText()).toBe("Last paragraph");
    expect(md.blockDOM("Last paragraph")).toBe(last);
    expect(md.editor.snapshot().text).toContain("rewritten elsewhere");
  });

  test("a change below the selection: the selection stays on its words", async () => {
    const md = await setup();
    md.selectText("bold words");
    md.editor.load(DOC.replace("Last paragraph ends the guide.", "A new last line.\n\nAnd another."));
    expect(md.selectedText()).toBe("bold words");
    expect(md.editor.snapshot().text).toContain("And another.");
  });

  test("a change inside the selected block keeps a valid selection and loads the new text", async () => {
    const md = await setup();
    md.selectText("Second paragraph");
    md.editor.load(DOC.replace("Second paragraph with", "Second paragraph now with"));
    expect(md.editor.snapshot().text).toBe(DOC.replace("Second paragraph with", "Second paragraph now with"));
    const { from, to } = md.view().state.selection;
    expect(from).toBeGreaterThanOrEqual(0);
    expect(to).toBeLessThanOrEqual(md.view().state.doc.content.size);
  });

  test("a load is still not undoable and still the save baseline", async () => {
    const md = await setup();
    const next = DOC.replace("First item", "First item, edited on disk");
    md.editor.load(next);
    expect(md.editor.baselineText()).toBe(next);
    expect(md.editor.snapshot().text).toBe(next);
  });
});

describe("what a selection reveals", () => {
  test("a caret in a highlight reveals its markers", async () => {
    const md = await setup();
    md.select(md.find("highlighted") + 3);
    expect(md.revealed()).toBe(2);
  });

  test("a selection inside a highlight reveals its markers", async () => {
    const md = await setup();
    md.selectText("highlighted");
    expect(md.revealed()).toBe(2);
  });

  test("a selection that crosses a highlight keeps its markers hidden", async () => {
    const md = await setup();
    md.select(md.find("First paragraph"), md.find("Last paragraph") + 4);
    expect(md.revealed()).toBe(0);
    expect(md.hidden()).toBe(2);
  });

  test("a selection that starts inside a highlight and leaves it keeps its markers hidden", async () => {
    const md = await setup();
    md.select(md.find("highlighted") + 2, md.find("and more") + 3);
    expect(md.revealed()).toBe(0);
  });

  test("select all keeps every marker hidden", async () => {
    const md = await setup();
    md.view().dispatch(md.view().state.tr.setSelection(new AllSelection(md.view().state.doc)));
    expect(md.revealed()).toBe(0);
  });
});

describe("while the button is down", () => {
  test("a selection change reveals nothing until the release", async () => {
    const md = await setup();
    md.select(md.find("Last paragraph"));
    md.press();
    md.select(md.find("highlighted") + 3);
    expect(md.revealed()).toBe(0);
    md.release();
    expect(md.revealed()).toBe(2);
  });

  test("the block marked active stays until the release", async () => {
    const md = await setup();
    md.select(md.find("Last paragraph"));
    const active = () => md.view().dom.querySelector(".md-active")?.textContent;
    expect(active()).toBe("Last paragraph ends the guide.");
    md.press();
    md.select(md.find("First paragraph"));
    expect(active()).toBe("Last paragraph ends the guide.");
    md.release();
    expect(active()).toBe("First paragraph with bold words in it.");
  });

  test("an edit while the button is down still updates the syntax", async () => {
    const md = await setup();
    md.select(md.find("and more"));
    md.press();
    md.view().dispatch(md.view().state.tr.insertText(" ==new== ", md.find("and more")));
    expect(md.hidden()).toBe(4);
    md.release();
  });
});
