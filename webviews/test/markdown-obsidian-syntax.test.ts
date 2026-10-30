// Obsidian's Markdown syntax in the markdown editor (MARKDOWN-OBSIDIAN-PARITY, user 2026-10-19:
// "Think about every kind of Markdown intricacy that Obsidian has and make sure that we have the
// same thing as well").
//
// The real editor on a jsdom page. Live Preview style: the file's text never changes; the editor
// draws the syntax (==highlights==, %%comments%%, #tags, [[wikilinks]], callouts, $math$) and
// hides the markers while the caret is outside them, as Obsidian does. Editing a paragraph that
// holds them writes them back as typed (no `\[\[` escapes).
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { TextSelection } from "@milkdown/kit/prose/state";
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

async function setup(text: string) {
  const root = document.createElement("div");
  document.body.append(root);
  const opened: string[] = [];
  const editor = new MarkdownEditor({
    root,
    host: { openLink: (href) => opened.push(href), imageURL: (src) => `asset:${src}`, label: (key) => key },
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
  return {
    editor,
    opened,
    root: () => view().dom as HTMLElement,
    markdown: () => editor.snapshot().text,
    caret(needle: string, offset = 0) {
      const at = find(needle) + offset;
      view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, at)));
    },
    type(value: string) {
      view().dispatch(view().state.tr.insertText(value));
    },
    texts: (selector: string) => [...view().dom.querySelectorAll(selector)].map((element) => element.textContent),
  };
}

describe("markdown Obsidian syntax", () => {
  test("==highlight== draws a highlight and hides its markers until the caret enters", async () => {
    const md = await setup("Start here.\n\nSome ==marked words== in a line.\n");
    md.caret("Start", 0);
    expect(md.texts(".md-highlight")).toEqual(["marked words"]);
    expect(md.texts(".md-syntax-hidden")).toEqual(["==", "=="]);
    md.caret("marked", 2);
    expect(md.texts(".md-syntax-hidden")).toEqual([]);
    expect(md.texts(".md-highlight")).toEqual(["marked words"]);
  });

  test("%%comments%% draw as comments", async () => {
    const md = await setup("Visible %%a private note%% text.\n");
    expect(md.texts(".md-comment").join("")).toContain("a private note");
  });

  test("#tags draw as tags; issue numbers and headings do not", async () => {
    const md = await setup("Filed under #project/alpha and #todo, see #123.\n");
    expect(md.texts(".md-tag")).toEqual(["#project/alpha", "#todo"]);
  });

  test("[[wikilinks]] draw as links (the alias when there is one) and Cmd-click opens the note", async () => {
    const md = await setup("Start here.\n\nSee [[Project Plan]] and [[notes/ideas#Next|the ideas]].\n");
    md.caret("Start", 0);
    expect(md.texts(".md-wikilink")).toEqual(["Project Plan", "the ideas"]);
    const link = md.root().querySelector<HTMLElement>(".md-wikilink")!;
    link.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true }));
    expect(md.opened).toEqual(["Project%20Plan.md"]);
    const second = md.root().querySelectorAll<HTMLElement>(".md-wikilink")[1]!;
    second.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true }));
    expect(md.opened[1]).toBe("notes/ideas.md#next");
  });

  test("editing a paragraph keeps [[wikilinks]], ==highlights== and #tags as typed", async () => {
    const md = await setup("See [[Project Plan]], ==this== and #todo.\n");
    md.caret("this", 0);
    md.type("all of ");
    expect(md.markdown()).toBe("See [[Project Plan]], ==all of this== and #todo.\n");
  });

  test("callouts: > [!type] draws a callout with its title; [!type]- starts folded", async () => {
    const md = await setup("> [!warning] Mind the gap\n> The body.\n\n> [!tip]-\n> Folded body.\n\n> A plain quote.\n");
    const callouts = [...md.root().querySelectorAll<HTMLElement>("blockquote.md-callout")];
    expect(callouts.map((element) => element.dataset.callout)).toEqual(["warning", "tip"]);
    expect(callouts[1]!.classList.contains("md-callout-folded")).toBe(true);
    expect(callouts[0]!.classList.contains("md-callout-folded")).toBe(false);
    expect(md.texts(".md-callout-default-title")).toEqual(["Tip"]);
    expect(md.markdown()).toBe(
      "> [!warning] Mind the gap\n> The body.\n\n> [!tip]-\n> Folded body.\n\n> A plain quote.\n",
    );
  });

  test("$math$ and $$math$$ render with KaTeX while the caret is outside them", async () => {
    const md = await setup("Start.\n\nEnergy $E = mc^2$ here.\n\n$$\n\\sum_{n=1}^{N} n\n$$\n");
    md.caret("Start", 0);
    // KaTeX loads on first use.
    for (let i = 0; i < 1000 && md.root().querySelectorAll(".md-math .katex").length < 2; i++)
      await new Promise((resolve) => setTimeout(resolve, 0));
    expect(md.root().querySelectorAll(".md-math-inline .katex").length).toBe(1);
    expect(md.root().querySelectorAll(".md-math-block .katex").length).toBe(1);
    md.caret("mc^2", 1);
    expect(md.root().querySelectorAll(".md-math-inline").length).toBe(0);
  });

  test("![alt|300](src) sizes the image", async () => {
    const md = await setup("![A chart|300](chart.png)\n");
    const image = md.root().querySelector("img")!;
    expect(image.getAttribute("width")).toBe("300");
    expect(image.alt).toBe("A chart");
  });
});
