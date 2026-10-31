// The markdown editor's link bubble (user 2026-10-19: "If I click on it I would want to see the link
// URL and be able to edit it, more similar to Google Docs. Right now it is only on hover, which I
// do not like at all. I can click on it and be able to remove the link completely as well.").
//
// The real editor (Milkdown over ProseMirror) runs on a jsdom page: the caret entering a link
// shows the bubble (URL, Open, Copy, Edit, Remove), hovering shows nothing, Edit changes the text
// and the URL, Remove keeps the text, Cmd-K inserts and edits, a URL pasted over a selection links
// it, a typed bare URL links itself, and every edit writes the markdown spelling the file used.
import { afterEach, beforeAll, describe, expect, jest, test } from "bun:test";
import { TextSelection } from "@milkdown/kit/prose/state";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";
import type { LinkHost } from "../src/pages/markdown/linkEditing";
import type { LinkBubbleState } from "../src/pages/markdown/overlays";

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
  // jsdom has no layout: ProseMirror's scroll-into-view and the bubble's anchor read one empty box.
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

interface Setup {
  editor: Editor;
  opened: string[];
  copied: string[];
  bubble(): LinkBubbleState | null;
  /** The markdown a save writes now. */
  markdown(): string;
  /** Puts the caret (or a selection) at the first occurrence of `needle` (+ `offset` chars). */
  caret(needle: string, offset?: number, length?: number): void;
  /** Types `text` the way the keyboard does (text input handlers first). */
  type(text: string): void;
}

async function setup(text: string): Promise<Setup> {
  const root = document.createElement("div");
  document.body.append(root);
  const opened: string[] = [];
  const copied: string[] = [];
  const links: LinkHost = {
    resolved: (path) => ({ exists: true, path: `/w/${path}`, kind: "markdown" }),
    requestLinks: () => {},
    linkLabel: (key) => key,
    copyText: async (value) => {
      copied.push(value);
    },
  };
  const editor = new MarkdownEditor({
    root,
    host: {
      openLink: (href) => opened.push(href),
      imageURL: (src) => src,
      label: (key) => key,
      links,
    },
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
    copied,
    bubble: () => editor.overlays.getState().bubble,
    markdown: () => editor.snapshot().text,
    caret(needle, offset = 0, length = 0) {
      const from = find(needle) + offset;
      const state = view().state;
      editor.focus();
      view().dispatch(state.tr.setSelection(TextSelection.create(state.doc, from, from + length)));
    },
    type(value) {
      for (const char of value) {
        const v = view();
        const { from, to } = v.state.selection;
        const handled = v.someProp("handleTextInput", (handle) => handle(v, from, to, char, () => v.state.tr));
        if (!handled) v.dispatch(v.state.tr.insertText(char, from, to));
      }
    },
  };
}

describe("markdown link bubble", () => {
  test("the caret entering a link shows the bubble with its URL; leaving the link hides it", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    expect(md.bubble()).toBe(null);
    md.caret("the docs", 3);
    const bubble = md.bubble();
    expect(bubble?.mode).toBe("view");
    expect(bubble?.href).toBe("https://docs.cmux.dev/start");
    expect(bubble?.text).toBe("the docs");
    md.caret("first", 2);
    expect(md.bubble()).toBe(null);
  });

  test("hovering a link shows nothing (no hover card)", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("first", 2);
    const anchor = md.editor.editorView()!.dom.querySelector("a[href]")!;
    // Past any hover delay, on a clock the test moves.
    jest.useFakeTimers();
    try {
      anchor.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
      anchor.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
      jest.advanceTimersByTime(900);
    } finally {
      jest.useRealTimers();
    }
    // A bubble opened from a promise or a later task would show by now.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(md.bubble()).toBe(null);
  });

  test("Open, Copy link and Option-Return act on the link under the caret", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("the docs", 1);
    md.bubble()!.open();
    md.bubble()!.copy();
    await Promise.resolve();
    expect(md.opened).toEqual(["https://docs.cmux.dev/start"]);
    expect(md.copied).toEqual(["https://docs.cmux.dev/start"]);
    const view = md.editor.editorView()!;
    view.dom.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", altKey: true, bubbles: true, cancelable: true }),
    );
    expect(md.opened).toEqual(["https://docs.cmux.dev/start", "https://docs.cmux.dev/start"]);
    // Option-Return opened the link; it typed no line break.
    expect(md.markdown()).toBe("Read [the docs](https://docs.cmux.dev/start) first.\n");
  });

  test("Edit changes the link's text and URL; Escape (cancel) changes nothing", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("the docs", 2);
    md.bubble()!.edit();
    expect(md.bubble()?.mode).toBe("edit");
    md.bubble()!.cancel();
    expect(md.markdown()).toBe("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("the docs", 2);
    md.bubble()!.edit();
    md.bubble()!.apply("the guide", "https://cmux.dev/guide");
    expect(md.markdown()).toBe("Read [the guide](https://cmux.dev/guide) first.\n");
  });

  test("Remove link keeps the text", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("the docs", 4);
    md.bubble()!.remove();
    expect(md.markdown()).toBe("Read the docs first.\n");
    expect(md.bubble()).toBe(null);
  });

  test("Cmd-K on a selection inserts a link; on a link it edits it", async () => {
    const md = await setup("Ship the release today.\n");
    md.caret("release", 0, "release".length);
    md.editor.openLinkPopover();
    const bubble = md.bubble();
    expect(bubble?.mode).toBe("edit");
    expect(bubble?.text).toBe("release");
    expect(bubble?.href).toBe("");
    bubble!.apply("release", "https://github.com/manaflow-ai/cmux/releases");
    expect(md.markdown()).toBe("Ship the [release](https://github.com/manaflow-ai/cmux/releases) today.\n");
    md.caret("release", 2);
    md.editor.openLinkPopover();
    expect(md.bubble()?.mode).toBe("edit");
    expect(md.bubble()?.href).toBe("https://github.com/manaflow-ai/cmux/releases");
    md.bubble()!.apply("release", "");
    expect(md.markdown()).toBe("Ship the release today.\n");
  });

  test("Cmd-K with no selection inserts the typed text as a link", async () => {
    const md = await setup("See the site.\n");
    md.caret("See ", 4);
    md.editor.openLinkPopover();
    md.bubble()!.apply("cmux", "https://cmux.dev");
    expect(md.markdown()).toBe("See [cmux](https://cmux.dev)the site.\n");
  });

  test("pasting a URL over selected text links the text", async () => {
    const md = await setup("Ship the release today.\n");
    md.caret("release", 0, "release".length);
    // jsdom has no ClipboardEvent; the plain text reaches the paste handlers as the slice.
    md.editor.editorView()!.pasteText("https://cmux.dev/releases", new Event("paste") as ClipboardEvent);
    expect(md.markdown()).toBe("Ship the [release](https://cmux.dev/releases) today.\n");
  });

  test("a typed bare URL links itself and stays a bare URL in the file", async () => {
    const md = await setup("Notes\n");
    md.caret("Notes", 5);
    md.type(" see https://cmux.dev/docs. ok");
    const view = md.editor.editorView()!;
    const marks: string[] = [];
    view.state.doc.descendants((node) => {
      const link = node.marks.find((mark) => mark.type.name === "link");
      if (node.isText && link) marks.push(`${node.text}=${link.attrs.href}`);
    });
    // The sentence's period is not part of the URL.
    expect(marks).toEqual(["https://cmux.dev/docs=https://cmux.dev/docs"]);
    expect(md.markdown()).toBe("Notes see https://cmux.dev/docs. ok\n");
  });

  test("editing a paragraph keeps each link's markdown spelling", async () => {
    const source =
      "A https://a.dev/x_y and <https://b.dev> and [c](https://c.dev) and [ref][r] and [r].\n\n[r]: https://r.dev\n";
    const md = await setup(source);
    md.caret("A ", 0);
    md.type("Z");
    expect(md.markdown()).toBe(`Z${source}`);
  });

  test("a reference link edited in the bubble keeps its reference and updates its definition", async () => {
    const md = await setup("See [the spec][spec].\n\n[spec]: https://old.dev/spec\n");
    md.caret("the spec", 2);
    md.bubble()!.edit();
    md.bubble()!.apply("the spec", "https://new.dev/spec");
    expect(md.markdown()).toBe("See [the spec][spec].\n\n[spec]: https://new.dev/spec\n");
  });

  test("typing inside a link keeps one bubble; Escape hides it until the caret leaves the link", async () => {
    const md = await setup("Read [the docs](https://docs.cmux.dev/start) first.\n");
    md.caret("the docs", 3);
    const first = md.bubble()!.id;
    md.type("ir");
    expect(md.bubble()?.id).toBe(first);
    expect(md.bubble()?.text).toBe("their docs");
    const view = md.editor.editorView()!;
    view.dom.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(md.bubble()).toBe(null);
    md.caret("docs", 1);
    expect(md.bubble()).toBe(null);
    md.caret("first", 1);
    md.caret("docs", 1);
    expect(md.bubble()?.mode).toBe("view");
  });

  test("Cmd-Z right after an autolink takes the link back and keeps the URL text", async () => {
    const md = await setup("Notes\n");
    md.caret("Notes", 5);
    md.type(" https://cmux.dev ");
    const { undo } = await import("@milkdown/kit/prose/history");
    const view = md.editor.editorView()!;
    undo(view.state, view.dispatch);
    // Plain text that would read as a URL is written escaped (GFM), so the file keeps it unlinked.
    expect(md.markdown()).toBe("Notes https\\://cmux.dev\n");
    let linked = false;
    view.state.doc.descendants((node) => {
      if (node.marks.some((mark) => mark.type.name === "link")) linked = true;
    });
    expect(linked).toBe(false);
  });
});
