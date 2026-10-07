// The markdown editor must never change a file the user did not edit (plans/cmux-next/diff-host.md
// S6; src/pages/markdown/sourceMap.ts). Every file of the corpus (real markdown from this repo plus
// a few synthetic edge cases) is loaded into the real editor and serialized with no edit: the text
// must be byte-identical. Edits must stay inside the edited block.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import fs from "node:fs";
import path from "node:path";
import type { MarkdownEditor as MarkdownEditorType } from "../src/pages/markdown/editor";

const corpusDir = path.join(import.meta.dir, "fixtures/markdown-roundtrip");
const corpus = fs
  .readdirSync(corpusDir)
  .filter((name) => name.endsWith(".md"))
  .sort();
const saved = new Map<string, unknown>();
let editor: MarkdownEditorType;

const DOM_GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "Text",
  "HTMLElement",
  "Element",
  "DOMParser",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getSelection",
  "Range",
  "KeyboardEvent",
  "MouseEvent",
  "DocumentFragment",
];

beforeAll(async () => {
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { pretendToBeVisual: true });
  for (const key of DOM_GLOBALS) {
    saved.set(key, (globalThis as Record<string, unknown>)[key]);
    (globalThis as Record<string, unknown>)[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  const { MarkdownEditor } = await import("../src/pages/markdown/editor");
  editor = new MarkdownEditor({
    root: dom.window.document.getElementById("root")!,
    host: { openLink() {}, imageURL: (src) => src, label: (key) => key },
  });
  await editor.create();
});

afterAll(async () => {
  await editor?.destroy();
  for (const [key, value] of saved) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
});

test("the corpus has 30 or more files", () => {
  expect(corpus.length).toBeGreaterThanOrEqual(30);
});

describe("no edit writes the file back byte for byte", () => {
  for (const name of corpus) {
    test(name, () => {
      const text = fs.readFileSync(path.join(corpusDir, name), "utf8");
      editor.load(text);
      expect(editor.snapshot().text).toBe(text);
    });
  }
});

describe("an edit changes only the edited block", () => {
  for (const name of corpus) {
    test(name, () => {
      const text = fs.readFileSync(path.join(corpusDir, name), "utf8");
      editor.load(text);
      const map = editor.snapshot();
      const view = editor.editorView()!;
      // The first paragraph (or heading) of the document gets one word typed at its start.
      let target = -1;
      view.state.doc.forEach((node, offset, index) => {
        if (target < 0 && (node.type.name === "paragraph" || node.type.name === "heading") && node.textContent) {
          target = index;
          view.dispatch(view.state.tr.insertText("Edited ", offset + 1));
        }
      });
      if (target < 0) return;
      let blockIndex = -1;
      let nodeCount = 0;
      map.blocks.forEach((block, index) => {
        if (blockIndex < 0 && target < nodeCount + block.nodes.length) blockIndex = index;
        nodeCount += block.nodes.length;
      });
      const block = map.blocks[blockIndex];
      const out = editor.snapshot().text;
      expect(out.slice(0, block.start)).toBe(text.slice(0, block.start));
      expect(out.slice(out.length - (text.length - block.end))).toBe(text.slice(block.end));
      expect(out).toContain("Edited ");
    });
  }
});

describe("structural edits", () => {
  const text =
    "# Title\n\nFirst *one*  \nwith break.\n\n* star list\n* two\n\n[ref]: https://example.com\n\nLast [link][ref].\n";
  const nodeAt = (index: number) => {
    const view = editor.editorView()!;
    let pos = 0;
    for (let i = 0; i < index; i++) pos += view.state.doc.child(i).nodeSize;
    return { view, pos, node: view.state.doc.child(index) };
  };

  test("undo returns the exact original", async () => {
    editor.load(text);
    const { view, pos } = nodeAt(1);
    view.dispatch(view.state.tr.insertText("X", pos + 1));
    expect(editor.snapshot().text).not.toBe(text);
    const { undo } = await import("@milkdown/kit/prose/history");
    undo(view.state, view.dispatch);
    expect(editor.snapshot().text).toBe(text);
  });

  test("deleting a block keeps its neighbors and the definition", () => {
    editor.load(text);
    const { view, pos, node } = nodeAt(1);
    view.dispatch(view.state.tr.delete(pos, pos + node.nodeSize));
    expect(editor.snapshot().text).toBe(
      "# Title\n\n* star list\n* two\n\n[ref]: https://example.com\n\nLast [link][ref].\n",
    );
  });

  test("a new paragraph is serialized between untouched blocks", () => {
    editor.load(text);
    const { view, pos, node } = nodeAt(2);
    const paragraph = view.state.schema.nodes.paragraph.create(null, view.state.schema.text("New para"));
    view.dispatch(view.state.tr.insert(pos + node.nodeSize, paragraph));
    expect(editor.snapshot().text).toBe(
      "# Title\n\nFirst *one*  \nwith break.\n\n* star list\n* two\n\nNew para\n\n[ref]: https://example.com\n\nLast [link][ref].\n",
    );
  });

  test("a save makes the result the next baseline", () => {
    editor.load(text);
    const { view, pos } = nodeAt(0);
    view.dispatch(view.state.tr.insertText("My ", pos + 1));
    const first = editor.snapshot();
    editor.commit(first);
    expect(editor.snapshot().text).toBe(first.text);
    expect(first.text).toBe(
      "# My Title\n\nFirst *one*  \nwith break.\n\n* star list\n* two\n\n[ref]: https://example.com\n\nLast [link][ref].\n",
    );
  });

  test("CRLF files keep CRLF in edited blocks", () => {
    const crlf = "# A\r\n\r\nB para\r\n";
    editor.load(crlf);
    const { view, pos } = nodeAt(1);
    view.dispatch(view.state.tr.insertText("C ", pos + 1));
    expect(editor.snapshot().text).toBe("# A\r\n\r\nC B para\r\n");
  });
});

test("the corpus parses without falling back to raw source blocks", () => {
  const fallbacks: string[] = [];
  for (const name of corpus) {
    editor.load(fs.readFileSync(path.join(corpusDir, name), "utf8"));
    editor.editorView()!.state.doc.forEach((node) => {
      if (node.type.name === "cmux_raw" && node.attrs.kind === "source")
        fallbacks.push(`${name}: ${node.textContent.slice(0, 60)}`);
    });
  }
  expect(fallbacks).toEqual([]);
});

test("an edited paragraph keeps its reference links", () => {
  const text =
    "See the [guide][g], [collapsed][] and ![logo][l] here.\n\n[g]: https://example.com/g\n[collapsed]: https://example.com/c\n[l]: ./logo.png\n";
  editor.load(text);
  const view = editor.editorView()!;
  view.dispatch(view.state.tr.insertText("Now: ", 1));
  expect(editor.snapshot().text).toBe(`Now: ${text}`);
});

test("checking a task rewrites only its list", () => {
  const text = "Intro *para*.\n\n* [ ] open\n* [x] done\n\nOutro.\n";
  editor.load(text);
  const view = editor.editorView()!;
  let itemPos = -1;
  view.state.doc.descendants((node, pos) => {
    if (itemPos < 0 && node.type.name === "list_item" && node.attrs.checked === false) itemPos = pos;
  });
  const item = view.state.doc.nodeAt(itemPos)!;
  view.dispatch(view.state.tr.setNodeMarkup(itemPos, undefined, { ...item.attrs, checked: true }));
  const out = editor.snapshot().text;
  expect(out.startsWith("Intro *para*.\n\n")).toBe(true);
  expect(out.endsWith("\n\nOutro.\n")).toBe(true);
  expect(out).toContain("[x] open");
});

test("task widgets expose their state and check mark", () => {
  editor.load("- [x] done\n- [ ] open\n");
  const checkboxes = [...editor.editorView()!.dom.querySelectorAll<HTMLElement>(".cmux-markdown-checkbox")];
  expect(checkboxes.map((checkbox) => checkbox.getAttribute("aria-checked"))).toEqual(["true", "false"]);
  expect(checkboxes[0]?.getAttribute("role")).toBe("checkbox");
  expect(checkboxes[0]?.getAttribute("aria-readonly")).toBe("true");
  expect(checkboxes[0]?.querySelector("path")).not.toBeNull();
});
