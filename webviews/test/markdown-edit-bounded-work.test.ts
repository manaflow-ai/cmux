// A keystroke in the Markdown viewer walks the blocks it changed, not the document: the plugins'
// work per edit is the same in a 10,000-line file as in a 1,000-line one. Before, Milkdown's heading
// id and list order syncs each walked every node, the broken-link plugin walked every heading, and
// a table view walked the document for its index on each edit in a cell.
import { afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";
import type { TableWidths } from "../src/pages/markdown/tables";

setDefaultTimeout(120_000);
let MarkdownEditor: typeof Editor;

beforeAll(async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
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
    "WheelEvent",
    "Event",
  ])
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  scope.ResizeObserver = class {
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
  (dom.window.document as unknown as { elementFromPoint: () => null }).elementFromPoint = () => null;
  ({ MarkdownEditor } = await import("../src/pages/markdown/editor"));
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
  document.body.innerHTML = "";
});

/** Saved table widths in memory: a table view looks its own up (by its index) on each update. */
function memoryWidths(): TableWidths {
  const saved = new Map<number, number[]>();
  return {
    get: (index) => saved.get(index) ?? null,
    set: (index, _header, widths) => void (widths ? saved.set(index, widths) : saved.delete(index)),
    clear: () => saved.clear(),
    subscribe: () => () => {},
  };
}

async function editor(): Promise<Editor> {
  const root = document.createElement("div");
  document.body.append(root);
  const next = new MarkdownEditor({
    root,
    host: {
      openLink: () => {},
      imageURL: (src) => src,
      label: (key) => key,
      githubRepository: "owner/repo",
      highlight: (code) =>
        [...code.matchAll(/\w+/g)].map((m) => ({ from: m.index!, to: m.index! + m[0].length, style: "color: red" })),
      tableWidths: memoryWidths(),
      links: {
        resolved: (path) => ({ exists: !path.includes("missing") }),
        requestLinks: () => {},
        linkLabel: (key) => key,
      },
    },
  });
  editors.push(next);
  await next.create();
  return next;
}

/** About `lines` lines: parts of a heading, anchor and file links, a table, task and ordered lists, and code. */
function markdown(lines: number): string {
  const part = (i: number) =>
    `## Part ${i}\n\nSee #${i} and [anchor](#part-${i}) and [file](notes/${i}.md) and ==mark ${i}==.\n\n` +
    `| name ${i} | value |\n| --- | --- |\n| cell ${i} | ${i} |\n\n- [ ] task ${i}\n- item ${i}\n\n` +
    `1. first ${i}\n2. second ${i}\n\n\`\`\`ts\nlet x${i} = ${i};\n\`\`\`\n\n`;
  const per = part(0).split("\n").length - 1;
  return Array.from({ length: Math.ceil(lines / per) }, (_, i) => part(i)).join("");
}

/** The position just after the first `needle` in the document's text. */
function textPos(doc: ProseNode, needle: string): number {
  let pos = -1;
  doc.descendants((node, at) => {
    if (pos >= 0) return false;
    if (node.isText && node.text!.includes(needle)) pos = at + node.text!.indexOf(needle) + needle.length;
    return true;
  });
  return pos;
}

/** The nodes `nodesBetween` and `descendants` visit (whoever calls them) while `run` runs. */
function visits(doc: ProseNode, run: () => void): number {
  const proto = Object.getPrototypeOf(doc) as ProseNode;
  const original = proto.nodesBetween;
  let count = 0;
  let depth = 0;
  proto.nodesBetween = function (this: ProseNode, from, to, f, start) {
    // Its own recursion into children is the same walk.
    if (depth) return original.call(this, from, to, f, start);
    depth++;
    try {
      return original.call(this, from, to, (...args) => (count++, f(...args)), start);
    } finally {
      depth--;
    }
  };
  try {
    run();
  } finally {
    proto.nodesBetween = original;
  }
  return count;
}

/** The nodes one keystroke visits: a character typed at the caret after `needle`, in the middle of the file. */
async function keystroke(lines: number, needle: (part: number) => string): Promise<number> {
  const { TextSelection } = await import("@milkdown/kit/prose/state");
  const opened = await editor();
  const text = markdown(lines);
  opened.load(text);
  opened.settle();
  const view = opened.editorView()!;
  const middle = Number(/Part (\d+)\n/.exec(text.slice(text.length / 2))![1]);
  const type = (part: number) => {
    const at = textPos(view.state.doc, needle(part));
    expect(at).toBeGreaterThan(0);
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, at)));
    return () => view.dispatch(view.state.tr.insertText("x"));
  };
  // One edit first: a keystroke while the user types, not the first after the load.
  type(middle - 1)();
  return visits(view.state.doc, type(middle));
}

test("a keystroke in a paragraph visits as many nodes in 10,000 lines as in 1,000", async () => {
  const small = await keystroke(1_000, (part) => `See #${part}`);
  const large = await keystroke(10_000, (part) => `See #${part}`);
  expect(small).toBeGreaterThan(0);
  expect(large).toBeLessThanOrEqual(small * 1.1);
});

test("a keystroke in a table cell visits as many nodes in 10,000 lines as in 1,000", async () => {
  const small = await keystroke(1_000, (part) => `cell ${part}`);
  const large = await keystroke(10_000, (part) => `cell ${part}`);
  expect(small).toBeGreaterThan(0);
  expect(large).toBeLessThanOrEqual(small * 1.1);
});

test("a keystroke in an ordered list visits as many nodes in 10,000 lines as in 1,000", async () => {
  const small = await keystroke(1_000, (part) => `second ${part}`);
  const large = await keystroke(10_000, (part) => `second ${part}`);
  expect(small).toBeGreaterThan(0);
  expect(large).toBeLessThanOrEqual(small * 1.1);
});
