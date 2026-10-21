// The markdown editor colors only the code blocks near the viewport. Coloring a block loads its
// language's grammar and tokenizes it on the main thread; a long file with code in many languages
// (the gallery's markdown showcase: 233 blocks in 193 languages) spent seconds coloring code nobody
// had scrolled to. A block that comes near is colored then, and keeps its colors while it is edited.
//
// The real editor on a jsdom page, with an IntersectionObserver the test drives.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { TextSelection } from "@milkdown/kit/prose/state";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;

/** Stands in for the browser's observer: the test says which observed elements come near. */
class TestIntersectionObserver {
  static all: TestIntersectionObserver[] = [];
  readonly observed = new Set<Element>();
  constructor(
    private readonly callback: (entries: { target: Element; isIntersecting: boolean }[]) => void,
    readonly options?: { root?: Element | null; rootMargin?: string },
  ) {
    TestIntersectionObserver.all.push(this);
  }
  observe(element: Element) {
    this.observed.add(element);
  }
  unobserve(element: Element) {
    this.observed.delete(element);
  }
  disconnect() {
    this.observed.clear();
  }
  show(elements: Element[]) {
    const targets = elements.filter((element) => this.observed.has(element));
    if (targets.length) this.callback(targets.map((target) => ({ target, isIntersecting: true })));
  }
}

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
  scope.IntersectionObserver = TestIntersectionObserver;
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
  TestIntersectionObserver.all = [];
});

const LANGUAGES = Array.from({ length: 30 }, (_, index) => `lang${index}`);
const FILE = LANGUAGES.map(
  (language, index) => `## Block ${index}\n\n\`\`\`${language}\nvalue${index} = ${index}\n\`\`\`\n`,
).join("\n");

async function setup() {
  const root = document.createElement("div");
  document.body.append(root);
  const asked: string[] = [];
  const editor = new MarkdownEditor({
    root,
    host: {
      openLink: () => undefined,
      imageURL: (src) => src,
      label: (key) => key,
      // Colors a block's first five characters, so a colored block shows a styled span.
      highlight: (_code, language) => {
        asked.push(language);
        return [{ from: 0, to: 5, style: "color: red" }];
      },
    },
  });
  editors.push(editor);
  await editor.create();
  editor.load(FILE);
  const view = () => editor.editorView()!;
  const blocks = () => [...view().dom.querySelectorAll<HTMLElement>(".md-code")];
  const colored = () => blocks().map((block) => block.querySelector("code [style]") !== null);
  const show = (indexes: number[]) => {
    const elements = indexes.map((index) => blocks()[index]!);
    for (const observer of TestIntersectionObserver.all) observer.show(elements);
  };
  return { asked, view, blocks, colored, show };
}

describe("markdown code highlighting near the viewport", () => {
  test("a long file colors only the code blocks near the viewport", async () => {
    const md = await setup();
    expect(md.blocks()).toHaveLength(LANGUAGES.length);
    // Nothing is near until the observer says so: no grammar is asked for.
    expect(md.asked).toEqual([]);
    md.show([0, 1]);
    expect(new Set(md.asked)).toEqual(new Set(["lang0", "lang1"]));
    expect(md.colored().filter(Boolean)).toHaveLength(2);
    expect(md.colored().slice(0, 2)).toEqual([true, true]);
  });

  test("a block that comes near later is colored then", async () => {
    const md = await setup();
    md.show([0]);
    md.show([20]);
    expect(new Set(md.asked)).toEqual(new Set(["lang0", "lang20"]));
    expect(md.colored()[20]).toBe(true);
    expect(md.colored()[10]).toBe(false);
  });

  test("a near block keeps its colors while it is edited, and edits above it keep it near", async () => {
    const md = await setup();
    md.show([3]);
    const inside = (index: number) => {
      let at = -1;
      md.view().state.doc.descendants((node, pos) => {
        if (at < 0 && node.type.name === "code_block" && node.textContent === `value${index} = ${index}`) at = pos + 1;
        return at < 0;
      });
      return at;
    };
    const type = (at: number, text: string) => {
      const view = md.view();
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, at)).insertText(text));
    };
    type(inside(3) + 2, "x");
    expect(md.colored()[3]).toBe(true);
    // Text typed in an earlier block moves block 3 down the document; it is still the near one.
    type(inside(1) + 1, "more text ");
    expect(md.colored()[3]).toBe(true);
    expect(md.colored().filter(Boolean)).toHaveLength(1);
  });
});
