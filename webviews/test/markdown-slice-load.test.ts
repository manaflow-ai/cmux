// A long markdown file opens in slices (MarkdownEditor.loadInSlices, found by
// bench/markdown-viewer-stress.bench.ts: a 1 MB file took 9.6 s to show anything and 10 MB never
// did). The first screen shows at once, the rest comes a task at a time, and at the end the
// document is the one a whole load gives; a save before the end writes the file unchanged, an edit
// before the end is refused, and a reload of the file appended to parses only its end. Leo,
// 2026-11-17: "we should be stress testing everything that isn't already stress tested".
import { afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

setDefaultTimeout(120_000);
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
  // jsdom has none; a table's view watches its size.
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

async function editor(): Promise<Editor> {
  const root = document.createElement("div");
  document.body.append(root);
  const next = new MarkdownEditor({ root, host: { openLink: () => {}, imageURL: (src) => src, label: (key) => key } });
  editors.push(next);
  await next.create();
  return next;
}

/** About `bytes` of headings, paragraphs, lists, tasks, tables and fences, ending in `tail`. */
function longFile(bytes: number, tail = "the end"): string {
  const parts: string[] = [];
  let size = 0;
  for (let i = 0; size < bytes; i++) {
    const part =
      `## Part ${i}\n\nSome **text** ${i} with a [link](https://example.com/${i}).\n\n` +
      `- one\n- [ ] two\n\n  continued\n\n| a | b |\n| - | - |\n| ${i} | x |\n\n\`\`\`ts\nlet x = ${i};\n\`\`\`\n\n`;
    parts.push(part);
    size += part.length;
  }
  return `${parts.join("")}${tail}\n`;
}

const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Waits task by task until the editor's document ends with `needle`. */
async function loaded(view: ReturnType<Editor["editorView"]>, needle: string): Promise<void> {
  for (let i = 0; i < 2_000 && !view!.state.doc.lastChild?.textContent.includes(needle); i++) await nextTask();
}

test("a long file shows its first slice at once and ends as a whole load", async () => {
  const text = longFile(400 * 1024);
  const sliced = await editor();
  sliced.load(text);
  const view = sliced.editorView()!;
  // The first slice is in before any task runs; the rest is not.
  expect(view.state.doc.firstChild!.textContent).toBe("Part 0");
  expect(view.state.doc.content.size).toBeLessThan(text.length / 4);
  await loaded(view, "the end");
  // Whole: the same text through a short-file load, block by block.
  const whole = await editor();
  const blocks: string[] = [];
  view.state.doc.forEach((node) => blocks.push(node.toString()));
  const wholeBlocks: string[] = [];
  for (const part of text.split(/(?=^## Part )/m)) {
    whole.load(part);
    whole.editorView()!.state.doc.forEach((node) => wholeBlocks.push(node.toString()));
  }
  expect(blocks.length).toBe(wholeBlocks.length);
  expect(blocks).toEqual(wholeBlocks);
  // Unedited, it writes the file back byte for byte.
  expect(sliced.snapshot().text).toBe(text);
});

test("before the last slice, a save writes the file as it is and an edit is refused", async () => {
  const text = longFile(400 * 1024);
  const sliced = await editor();
  sliced.load(text);
  const view = sliced.editorView()!;
  expect(sliced.snapshot().text).toBe(text);
  const size = view.state.doc.content.size;
  view.dispatch(view.state.tr.insertText("typed", 1));
  expect(view.state.doc.content.size).toBe(size);
  await loaded(view, "the end");
  view.dispatch(view.state.tr.insertText("typed", 1));
  expect(view.state.doc.firstChild!.textContent).toBe("typedPart 0");
});

test("a reload of the file appended to keeps every block before the end", async () => {
  const text = longFile(200 * 1024);
  const sliced = await editor();
  sliced.load(text);
  const view = sliced.editorView()!;
  await loaded(view, "the end");
  const before: unknown[] = [];
  view.state.doc.forEach((node) => before.push(node));
  sliced.load(`${text}\nappended paragraph\n`);
  // In this task, with no slices: the change is small.
  expect(view.state.doc.lastChild!.textContent).toBe("appended paragraph");
  const after: unknown[] = [];
  view.state.doc.forEach((node) => after.push(node));
  // Every block but the last two is the same node (its DOM is kept).
  let same = 0;
  while (same < before.length && before[same] === after[same]) same++;
  expect(same).toBeGreaterThanOrEqual(before.length - 2);
  expect(sliced.snapshot().text).toBe(`${text}\nappended paragraph\n`);
});
